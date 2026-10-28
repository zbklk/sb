"""Regression test: actually start the generated unit under its systemd sandbox.

Run as root on a systemd Linux host, with RUN_SYSTEMD_TESTS=1 and SING_BOX set.
Only a uniquely named temporary unit and files below /run are created.
"""
import os
from pathlib import Path
import shlex
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest

from test_anytls import CORE, SCRIPT, certificate, free_port, inline_python


@unittest.skipUnless(os.environ.get("RUN_SYSTEMD_TESTS") == "1", "separate privileged systemd test step")
class SystemdSandbox(unittest.TestCase):
    def test_generated_unit_starts_and_accepts_ipv6_tls(self):
        import grp
        import pwd
        self.assertEqual(os.geteuid(), 0, "run systemd regression test as root")
        self.assertTrue(Path("/run/systemd/system").is_dir(), "systemd must be running")
        self.assertTrue(CORE, "SING_BOX must be set")
        user = pwd.getpwnam("daemon")
        group = grp.getgrnam("daemon")
        with tempfile.TemporaryDirectory(prefix="anytls-systemd-ci-", dir="/run") as folder:
            folder = Path(folder)
            os.chown(folder, 0, group.gr_gid)
            folder.chmod(0o750)
            cert, key = certificate(folder, "server")
            binary = folder / "sing-box"
            shutil.copyfile(CORE, binary)
            binary.chmod(0o755)
            port = free_port(socket.AF_INET6)
            subprocess.run([sys.executable, "-", str(folder), "::1", "127.0.0.1", str(port),
                            "temporary-ci-only-password", "anytls.invalid", str(cert), str(key), "1"],
                           input=inline_python("make_bundle"), text=True, check=True)
            for path in (cert, key, folder / "config.json"):
                os.chown(path, 0, group.gr_gid)
                path.chmod(0o640)
            unit_name = folder.name + ".service"
            unit_path = Path("/run/systemd/system") / unit_name
            self.assertFalse(unit_path.exists(), "refuse to overwrite an existing unit")
            command = (f"source {shlex.quote(str(SCRIPT))}\nNAME={shlex.quote(user.pw_name)}\n"
                       f"DIR={shlex.quote(str(folder))}\nBIN={shlex.quote(str(binary))}\n"
                       f"CONF={shlex.quote(str(folder / 'config.json'))}\n"
                       f"UNIT={shlex.quote(str(unit_path))}\ncreate_unit\n")
            try:
                subprocess.run(["bash", "-c", command], check=True)
                unit_path.chmod(0o644)
                subprocess.run(["systemctl", "daemon-reload"], check=True)
                subprocess.run(["systemctl", "start", unit_name], check=True)
                context = ssl.create_default_context(cafile=str(cert))
                deadline = time.monotonic() + 10
                connected = False
                while time.monotonic() < deadline:
                    try:
                        with socket.create_connection(("::1", port), timeout=0.5) as connection:
                            with context.wrap_socket(connection, server_hostname="anytls.invalid"):
                                connected = True
                        break
                    except OSError:
                        time.sleep(0.1)
                logs = subprocess.run(["journalctl", "-u", unit_name, "--no-pager", "-n", "30"],
                                      capture_output=True, text=True).stdout
                self.assertTrue(connected, "generated service never became ready:\n" + logs)
                state = subprocess.run(["systemctl", "is-active", "--quiet", unit_name])
                self.assertEqual(state.returncode, 0, logs)
                # Verify the service is genuinely subject to the address-family filter.
                families = subprocess.check_output(["systemctl", "show", unit_name,
                              "--property=RestrictAddressFamilies", "--value"], text=True)
                self.assertIn("AF_NETLINK", families)
                self.assertNotIn("FATAL", logs)
            finally:
                subprocess.run(["systemctl", "stop", unit_name], capture_output=True)
                subprocess.run(["systemctl", "reset-failed", unit_name], capture_output=True)
                unit_path.unlink(missing_ok=True)
                subprocess.run(["systemctl", "daemon-reload"], check=True)


if __name__ == "__main__":
    unittest.main()
