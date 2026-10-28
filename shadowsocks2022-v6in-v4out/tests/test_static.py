"""Offline structural/regression tests for the independent SS2022 installer."""
import base64
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from urllib.parse import urlsplit

SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"

class ShadowsocksInstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SCRIPT.read_text(encoding="utf-8")
        cls.functions = cls.source.rsplit('main "$@"', 1)[0]

    def invoke(self, invocation, *args):
        result = subprocess.run(
            ["bash", "-c", self.functions + "\n" + invocation, "test", *map(str, args)],
            capture_output=True, text=True,
        )
        if result.returncode:
            self.fail(f"Bash function returned {result.returncode}:\n{result.stderr}")
        return result.stdout

    def test_bash_syntax(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    def test_help(self):
        result = subprocess.run(["bash", str(SCRIPT), "--help"], capture_output=True, text=True, check=True)
        self.assertIn("38444", result.stdout)
        self.assertIn("IPv4", result.stdout)

    def test_independent_service(self):
        self.assertIn("NAME=ss2022-v6v4", self.source)
        self.assertIn("SERVICE=$NAME.service", self.source)
        self.assertIn("发现已有 $NAME 节点，拒绝覆盖", self.source)
        self.assertIn("systemctl enable --now", self.source)
        self.assertNotIn("systemctl stop xray-v6v4", self.source)

    def test_ss2022_config_and_uri(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / "config.json"
            client = Path(temp) / "client.txt"
            password = base64.b64encode(bytes(range(32))).decode()
            self.invoke(
                'make_config "$1" "$2" "$3" "$4" "$5"',
                config, "2a12:bec0:16f:101::", "185.115.207.154", "38444", password,
            )
            c = json.loads(config.read_text(encoding="utf-8"))
            inbound = c["inbounds"][0]
            self.assertEqual(inbound["protocol"], "shadowsocks")
            self.assertEqual(inbound["listen"], "2a12:bec0:16f:101::")
            self.assertEqual(inbound["port"], 38444)
            self.assertEqual(inbound["settings"]["method"], "2022-blake3-aes-256-gcm")
            self.assertEqual(inbound["settings"]["password"], password)
            self.assertEqual(inbound["settings"]["network"], "tcp,udp")
            self.assertNotIn("reality", json.dumps(c).lower())
            outbound = c["outbounds"][0]
            self.assertEqual(outbound["protocol"], "freedom")
            self.assertEqual(outbound["sendThrough"], "185.115.207.154")
            self.assertEqual(outbound["settings"]["domainStrategy"], "AsIs")
            self.assertEqual(outbound["streamSettings"]["sockopt"]["domainStrategy"], "ForceIPv4")
            self.assertEqual(c["routing"]["rules"][0]["outboundTag"], "ipv4-direct")
            self.assertEqual(c["dns"]["queryStrategy"], "UseIPv4")

            if shutil.which("xray"):
                server_check = subprocess.run(
                    ["xray", "run", "-test", "-format", "json", "-config", str(config)],
                    capture_output=True, text=True,
                )
                self.assertEqual(server_check.returncode, 0, server_check.stderr + server_check.stdout)
                proxy_client = {
                    "inbounds": [{"listen": "127.0.0.1", "port": 24567, "protocol": "socks", "settings": {"auth": "noauth"}}],
                    "outbounds": [{"protocol": "shadowsocks", "settings": {
                        "address": inbound["listen"], "port": inbound["port"],
                        "method": inbound["settings"]["method"],
                        "password": inbound["settings"]["password"],
                    }}],
                }
                proxy_file = Path(temp) / "proxy-client.json"
                proxy_file.write_text(json.dumps(proxy_client), encoding="utf-8")
                client_check = subprocess.run(
                    ["xray", "run", "-test", "-format", "json", "-config", str(proxy_file)],
                    capture_output=True, text=True,
                )
                self.assertEqual(client_check.returncode, 0, client_check.stderr + client_check.stdout)

            self.invoke('make_client "$1" "$2"', config, client)
            line = next(line for line in client.read_text(encoding="utf-8").splitlines() if line.startswith("ss://"))
            url = urlsplit(line)
            self.assertEqual(url.scheme, "ss")
            self.assertEqual(url.hostname, "2a12:bec0:16f:101::")
            self.assertEqual(url.port, 38444)
            data = url.username + "=" * (-len(url.username) % 4)
            decoded = base64.urlsafe_b64decode(data).decode()
            self.assertEqual(decoded, f"2022-blake3-aes-256-gcm:{password}")

    def test_staged_xray_config_json(self):
        self.assertIn('make_config "$stage/config.json"', self.source)
        self.assertIn('xray run -test -format json -config "$stage/config.json"', self.source)
        self.assertIn('xray run -test -format json -config "$tmp/client.json"', self.source)

if __name__ == "__main__":
    unittest.main()
