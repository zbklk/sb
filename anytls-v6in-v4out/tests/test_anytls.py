"""Run the installer's generator and real sing-box on isolated loopback sockets.

No root, public DNS, Internet targets, or system services are used.
SING_BOX must point to the pinned official 1.14.4 executable.
"""
import copy
import datetime
import http.server
import ipaddress
import json
import os
from pathlib import Path
import shutil
import shlex
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"
CORE = os.environ.get("SING_BOX", shutil.which("sing-box"))


def inline_python(function):
    source = SCRIPT.read_text(encoding="utf-8").split(function + "() {", 1)[1]
    return source.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]


def certificate(folder, name):
    cert, key = folder / (name + ".crt"), folder / (name + ".key")
    if shutil.which("openssl"):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                        "ec_paramgen_curve:P-256", "-nodes", "-days", "2", "-subj",
                        "/CN=anytls.invalid", "-addext", "subjectAltName=DNS:anytls.invalid",
                        "-addext", "basicConstraints=critical,CA:TRUE", "-keyout", str(key),
                        "-out", str(cert)], check=True, capture_output=True)
    else:  # Bundled Windows test runtime; Linux CI uses OpenSSL above.
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import NameOID
        private = ec.generate_private_key(ec.SECP256R1())
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "anytls.invalid")])
        now = datetime.datetime.now(datetime.timezone.utc)
        public = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                  .public_key(private.public_key()).serial_number(x509.random_serial_number())
                  .not_valid_before(now - datetime.timedelta(minutes=1))
                  .not_valid_after(now + datetime.timedelta(days=2))
                  .add_extension(x509.SubjectAlternativeName([x509.DNSName("anytls.invalid")]), False)
                  .add_extension(x509.BasicConstraints(ca=True, path_length=None), True)
                  .sign(private, hashes.SHA256()))
        cert.write_bytes(public.public_bytes(serialization.Encoding.PEM))
        key.write_bytes(private.private_bytes(serialization.Encoding.PEM,
                        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    return cert, key


def free_port(family=socket.AF_INET):
    with socket.socket(family) as sock:
        sock.bind(("::1" if family == socket.AF_INET6 else "127.0.0.1", 0))
        return sock.getsockname()[1]


def receive(sock, count):
    data = b""
    while len(data) < count:
        block = sock.recv(count - len(data))
        if not block:
            raise OSError("proxy closed the connection")
        data += block
    return data


class DNS:
    """Deterministic IPv4 DNS: dual.test has both families; v6.test only AAAA."""
    def __init__(self):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.settimeout(0.1)
        self.port = self.socket.getsockname()[1]
        self.queries = []
        self.running = True
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while self.running:
            try:
                data, peer = self.socket.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            end, labels = 12, []
            while data[end]:
                length = data[end]; end += 1
                labels.append(data[end:end + length].decode()); end += length
            end += 1
            kind = struct.unpack("!H", data[end:end + 2])[0]
            name = ".".join(labels)
            self.queries.append((name, kind))
            question = data[12:end + 4]
            answer = b""
            if kind == 1 and name == "dual.test":
                answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 1, 4) + socket.inet_aton("127.0.0.1")
            elif kind == 28:
                answer = b"\xc0\x0c" + struct.pack("!HHIH", 28, 1, 1, 16) + socket.inet_pton(socket.AF_INET6, "::1")
            header = data[:2] + struct.pack("!HHHHH", 0x8180, 1, int(bool(answer)), 0, 0)
            self.socket.sendto(header + question + answer, peer)

    def close(self):
        self.running = False
        self.thread.join(timeout=1)
        self.socket.close()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.peers.append(self.client_address[0])
        self.send_response(200)
        self.send_header("Content-Length", "8")
        self.end_headers()
        self.wfile.write(b"IPv4-OK\n")

    def log_message(self, *_):
        pass


@unittest.skipUnless(CORE, "set SING_BOX to the official pinned test binary")
class AnyTLS(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="anytls-test-")
        cls.folder = Path(cls.temp.name)
        cls.cert, cls.key = certificate(cls.folder, "server")
        cls.v6port = free_port(socket.AF_INET6)
        # Execute the exact embedded Python used by the installer, including JSON escaping.
        cls.password = 'test-only:"\\@?#密钥'
        subprocess.run([sys.executable, "-", str(cls.folder), "::1", "127.0.0.1",
                        str(cls.v6port), cls.password, "anytls.invalid", str(cls.cert), str(cls.key), "1"],
                       input=inline_python("make_bundle"), text=True, check=True)
        cls.server = json.loads((cls.folder / "config.json").read_text(encoding="utf-8"))
        cls.client = json.loads((cls.folder / "client.json").read_text(encoding="utf-8"))
        cls.processes = []
        cls.logs = []
        cls.dns = DNS()
        cls.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.http.peers = []
        cls.http_thread = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.http_thread.start()
        config = copy.deepcopy(cls.server)
        # Keep the production resolver strategy and IPv6 rejection. Only the test DNS
        # transport and a narrowly scoped IPv4 loopback target exception are changed.
        config["dns"]["servers"][0] = {"type": "udp", "tag": "dns4", "server": "127.0.0.1",
                                      "server_port": cls.dns.port, "inet4_bind_address": "127.0.0.1"}
        config["route"]["rules"].insert(2, {"ip_cidr": ["127.0.0.1/32"], "action": "route", "outbound": "ipv4-direct"})
        cls.launch(config, "server-run", "::1", cls.v6port)
        cls.socks = cls.launch_client(cls.client, "client-run")

    @classmethod
    def launch(cls, config, name, host, port):
        path = cls.folder / (name + ".json")
        path.write_text(json.dumps(config), encoding="utf-8")
        check = subprocess.run([CORE, "check", "-c", str(path)], capture_output=True, text=True)
        if check.returncode:
            raise AssertionError(check.stdout + check.stderr)
        log = open(cls.folder / (name + ".log"), "w+", encoding="utf-8")
        cls.logs.append(log)
        process = subprocess.Popen([CORE, "run", "-c", str(path)], stdout=log, stderr=log,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        cls.processes.append(process)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if process.poll() is not None:
                log.seek(0); raise AssertionError(log.read())
            try:
                with socket.create_connection((host, port), timeout=0.2):
                    return
            except OSError:
                time.sleep(0.05)
        raise AssertionError("sing-box listener did not start")

    @classmethod
    def launch_client(cls, config, name):
        config = copy.deepcopy(config)
        port = free_port()
        config["inbounds"][0]["listen_port"] = port
        cls.launch(config, name, "127.0.0.1", port)
        return port

    def fetch(self, host, port=None, socks=None):
        port = port or self.http.server_port
        with socket.create_connection(("127.0.0.1", socks or self.socks), timeout=5) as sock:
            sock.settimeout(5)
            sock.sendall(b"\x05\x01\x00")
            self.assertEqual(receive(sock, 2), b"\x05\x00")
            try:
                address = ipaddress.ip_address(host)
                encoded = (b"\x01" if address.version == 4 else b"\x04") + address.packed
            except ValueError:
                raw = host.encode()
                encoded = b"\x03" + bytes([len(raw)]) + raw
            sock.sendall(b"\x05\x01\x00" + encoded + struct.pack("!H", port))
            reply = receive(sock, 4)
            if reply[1]:
                raise OSError("SOCKS request rejected")
            if reply[3] == 1: receive(sock, 6)
            elif reply[3] == 4: receive(sock, 18)
            else: receive(sock, receive(sock, 1)[0] + 2)
            sock.sendall(b"GET / HTTP/1.0\r\nHost: test\r\n\r\n")
            response = b""
            while True:
                block = sock.recv(4096)
                if not block: break
                response += block
            if b"IPv4-OK" not in response:
                raise OSError("no HTTP response through AnyTLS")
            return response

    def test_generated_production_configs(self):
        self.assertEqual(self.server["inbounds"][0]["listen"], "::1")
        self.assertEqual(self.client["outbounds"][0]["password"], self.password)
        self.assertFalse(self.client["outbounds"][0]["tls"]["insecure"])
        self.assertNotIn("anytls://", (self.folder / "client.txt").read_text(encoding="utf-8"))
        for name in ("config.json", "client.json"):
            result = subprocess.run([CORE, "check", "-c", str(self.folder / name)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ipv4_literal_through_real_anytls(self):
        self.assertIn(b"IPv4-OK", self.fetch("127.0.0.1"))
        self.assertEqual(self.http.peers[-1], "127.0.0.1")

    def test_dual_stack_domain_uses_only_a_records(self):
        self.assertIn(b"IPv4-OK", self.fetch("dual.test"))
        queries = [kind for name, kind in self.dns.queries if name == "dual.test"]
        self.assertTrue(queries)
        self.assertEqual(set(queries), {1})

    def test_aaaa_only_domain_fails_without_ipv6_fallback(self):
        with self.assertRaises(OSError): self.fetch("v6.test")
        self.assertEqual({kind for name, kind in self.dns.queries if name == "v6.test"}, {1})

    def test_ipv6_literal_rejected_before_dial(self):
        class HTTP6(http.server.ThreadingHTTPServer):
            address_family = socket.AF_INET6
        target = HTTP6(("::1", 0), Handler)
        target.peers = []
        thread = threading.Thread(target=target.serve_forever, daemon=True)
        thread.start()
        try:
            with self.assertRaises(OSError): self.fetch("::1", target.server_port)
            self.assertEqual(target.peers, [])
        finally:
            target.shutdown(); target.server_close(); thread.join()

    def test_anytls_listener_has_no_ipv4_socket(self):
        with self.assertRaises(OSError):
            with socket.create_connection(("127.0.0.1", self.v6port), timeout=1): pass

    def test_bad_password_rejected(self):
        config = copy.deepcopy(self.client)
        config["outbounds"][0]["password"] = "wrong-test-only-password"
        port = self.launch_client(config, "bad-password")
        with self.assertRaises(OSError): self.fetch("127.0.0.1", socks=port)

    def test_untrusted_certificate_rejected(self):
        other_cert, _ = certificate(self.folder, "other")
        config = copy.deepcopy(self.client)
        config["outbounds"][0]["tls"]["certificate"] = other_cert.read_text().splitlines()
        port = self.launch_client(config, "bad-cert")
        with self.assertRaises(OSError): self.fetch("127.0.0.1", socks=port)

    def udp_exchange(self, host, target_port):
        with socket.create_connection(("127.0.0.1", self.socks), timeout=5) as control:
            control.settimeout(5)
            control.sendall(b"\x05\x01\x00")
            self.assertEqual(receive(control, 2), b"\x05\x00")
            control.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
            reply = receive(control, 4)
            self.assertEqual(reply[1], 0)
            self.assertEqual(reply[3], 1)
            relay = socket.inet_ntoa(receive(control, 4))
            relay_port = struct.unpack("!H", receive(control, 2))[0]
            address = ipaddress.ip_address(host)
            header = b"\x00\x00\x00" + (b"\x01" if address.version == 4 else b"\x04") + address.packed + struct.pack("!H", target_port)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as packet:
                packet.settimeout(2)
                packet.sendto(header + b"UDP-IPv4-OK", (relay, relay_port))
                return packet.recvfrom(4096)[0]

    def test_udp_ipv4_through_anytls_tcp_tunnel(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as target:
            target.bind(("127.0.0.1", 0)); target.settimeout(3)
            peers = []
            def echo():
                data, peer = target.recvfrom(4096)
                peers.append(peer[0]); target.sendto(data, peer)
            thread = threading.Thread(target=echo, daemon=True)
            thread.start()
            response = self.udp_exchange("127.0.0.1", target.getsockname()[1])
            thread.join(timeout=4)
            self.assertTrue(response.endswith(b"UDP-IPv4-OK"))
            self.assertEqual(peers, ["127.0.0.1"])

    def test_udp_ipv6_literal_rejected(self):
        with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as target:
            target.bind(("::1", 0)); target.settimeout(0.2)
            with self.assertRaises(OSError): self.udp_exchange("::1", target.getsockname()[1])
            with self.assertRaises(socket.timeout): target.recvfrom(4096)

    @unittest.skipUnless(os.name == "posix" and shutil.which("openssl"), "Linux/OpenSSL installer preflight")
    def test_installer_certificate_hostname_preflight(self):
        for sni, expected in (("anytls.invalid", 0), ("wrong.invalid", 1)):
            stage = self.folder / sni
            stage.mkdir()
            command = (f"source {shlex.quote(str(SCRIPT))}\n"
                       f"CERT={shlex.quote(str(self.cert))}\nKEY={shlex.quote(str(self.key))}\n"
                       f"SERVER_NAME={shlex.quote(sni)}\nmake_certificate {shlex.quote(str(stage))}\n")
            result = subprocess.run(["bash", "-c", command], capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    @classmethod
    def tearDownClass(cls):
        for process in cls.processes:
            process.terminate()
        for process in cls.processes:
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        for log in cls.logs: log.close()
        cls.http.shutdown(); cls.http.server_close(); cls.http_thread.join()
        cls.dns.close()
        cls.temp.cleanup()


if __name__ == "__main__": unittest.main()
