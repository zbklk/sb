"""Multi-node isolation, legacy compatibility, URI and real QR round trips."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.parse

from test_anytls import SCRIPT, inline_python


class ShareURI(unittest.TestCase):
    def test_standard_uri_encoding_and_explicit_tls_modes(self):
        with tempfile.TemporaryDirectory(prefix="anytls-uri-") as folder:
            folder = Path(folder)
            password = 'synthetic-only:@/密钥?%#'
            config = {"inbounds": [{"type": "anytls", "listen": "2001:db8::99", "listen_port": 38445,
                      "users": [{"password": password}], "tls": {"server_name": "anytls.invalid"}}]}
            (folder / "config.json").write_text(json.dumps(config), encoding="utf-8")
            (folder / "client.json").write_text('{"outbounds": []}', encoding="utf-8")
            (folder / "node-name").write_text("手机 2 #测试", encoding="utf-8")
            for insecure in ("0", "1"):
                result = subprocess.run([sys.executable, "-", str(folder / "config.json"),
                       str(folder / "client.json"), str(folder / "node-name"), "phone2", insecure],
                       input=inline_python("share_uri"), text=True, encoding="utf-8", check=True, capture_output=True)
                parsed = urllib.parse.urlsplit(result.stdout.strip())
                self.assertEqual(parsed.scheme, "anytls")
                self.assertEqual(parsed.hostname, "2001:db8::99")
                self.assertEqual(parsed.port, 38445)
                self.assertEqual(urllib.parse.unquote(parsed.username), password)
                self.assertEqual(urllib.parse.parse_qs(parsed.query), {"sni": ["anytls.invalid"], "insecure": [insecure]})
                self.assertEqual(urllib.parse.unquote(parsed.fragment), "手机 2 #测试")
                self.assertEqual(parsed.path, "/")


@unittest.skipUnless(os.name == "posix", "Bash/qrencode lifecycle checks run on Linux CI")
class NodeManagement(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="anytls-nodes-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        for name in ("config", "bin", "units"):
            (self.folder / name).mkdir()

    def run_bash(self, body, input=None):
        command = (f"source {shlex.quote(str(SCRIPT))}\n"
                   f"CONFIG_ROOT={shlex.quote(str(self.folder / 'config'))}\n"
                   f"BINARY_ROOT={shlex.quote(str(self.folder / 'bin'))}\n"
                   f"UNIT_ROOT={shlex.quote(str(self.folder / 'units'))}\n" + body)
        return subprocess.run(["bash", "-c", command], input=input, capture_output=True,
                              text=True, encoding="utf-8")

    def fixture(self, identifier, port):
        name = "anytls-v6v4" + ("" if identifier == "default" else "-" + identifier)
        folder = self.folder / "config" / name
        folder.mkdir()
        config = {"inbounds": [{"type": "anytls", "listen": "2001:db8::99", "listen_port": port,
                  "users": [{"password": "synthetic-private-" + identifier}], "tls": {"server_name": "anytls.invalid"}}]}
        (folder / "config.json").write_text(json.dumps(config), encoding="utf-8")
        (folder / "client.json").write_text('{"outbounds": [{"tls": {"insecure": false}}]}', encoding="utf-8")
        (folder / "client.txt").write_text("legacy client credentials\n", encoding="utf-8")
        binary_folder = self.folder / "bin" / name
        binary_folder.mkdir()
        binary = binary_folder / "sing-box"
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o755)
        (self.folder / "units" / (name + ".service")).write_text("test-unit\n")
        return folder

    def test_default_paths_match_legacy_and_named_nodes_are_independent(self):
        default = self.fixture("default", 38445)
        snapshot = {p.name: p.read_bytes() for p in default.iterdir()}
        result = self.run_bash('select_node default\nprintf "%s\\n" "$NAME" "$DIR" "$SERVICE"\n'
                               'select_node phone2\nprintf "%s\\n" "$NAME" "$DIR" "$SERVICE"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["anytls-v6v4", str(default), "anytls-v6v4.service",
                         "anytls-v6v4-phone2", str(self.folder / "config" / "anytls-v6v4-phone2"),
                         "anytls-v6v4-phone2.service"])
        self.assertEqual(snapshot, {p.name: p.read_bytes() for p in default.iterdir()})

    def test_bad_node_ids_cannot_escape_managed_paths(self):
        for identifier in ("../other", "/etc/other", "a/b", "UPPER", "-bad", "bad-", "a" * 21, ""):
            result = self.run_bash("select_node " + shlex.quote(identifier) + "\n")
            self.assertNotEqual(result.returncode, 0, identifier)
        self.assertEqual(list((self.folder / "config").iterdir()), [])

    def test_suggested_port_and_list_preserve_old_passwords(self):
        default = self.fixture("default", 38445)
        self.fixture("phone2", 38446)
        before = (default / "config.json").read_bytes()
        result = self.run_bash('systemctl() { printf "active\\n"; }\nsuggest_port\nlist_nodes\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("38447\n"))
        self.assertIn("phone2", result.stdout)
        self.assertIn("default", result.stdout)
        self.assertNotIn("synthetic-private", result.stdout)
        self.assertEqual(before, (default / "config.json").read_bytes())

    def test_removing_one_node_leaves_existing_node_untouched(self):
        default = self.fixture("default", 38445)
        removed = self.fixture("phone2", 38446)
        before = {p.name: p.read_bytes() for p in default.iterdir()}
        result = self.run_bash('select_node phone2\nYES=1\nsystemctl() { return 0; }\n'
                               'do_backup() { printf "backup-completed\\n"; }\ndo_uninstall\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("backup-completed", result.stdout)
        self.assertFalse(removed.exists())
        self.assertFalse((self.folder / "units" / "anytls-v6v4-phone2.service").exists())
        self.assertEqual(before, {p.name: p.read_bytes() for p in default.iterdir()})
        self.assertTrue((self.folder / "units" / "anytls-v6v4.service").exists())

    def test_menu_survives_failed_child_and_accepts_exit(self):
        # Stub child execution; no installer or system mutation runs in this menu test.
        result = self.run_bash('bash() { return 1; }\nshow_menu\n', input="1\n0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("安装失败，菜单继续可用", result.stdout)
        self.assertEqual(result.stdout.count("=== AnyTLS 节点管理"), 2)

    def test_png_decodes_to_exact_standard_uri_in_both_modes(self):
        self.assertTrue(shutil.which("qrencode"), "CI must install qrencode")
        self.assertTrue(shutil.which("zbarimg"), "CI must install zbar-tools")
        folder = self.fixture("default", 38445)
        before = (folder / "config.json").read_bytes()
        for insecure, mode in (("0", "strict"), ("1", "insecure")):
            result = self.run_bash('select_node default\nALLOW_INSECURE=' + insecure + '\nshow_qr\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            png = folder / ("qr-" + mode + ".png")
            self.assertEqual(png.stat().st_mode & 0o777, 0o600)
            decoded = subprocess.run(["zbarimg", "--quiet", "--raw", str(png)],
                                     check=True, capture_output=True, text=True).stdout.strip()
            uri = self.run_bash('select_node default\nshare_uri ' + insecure + '\n').stdout.strip()
            self.assertEqual(decoded, uri)
            self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(decoded).query)["insecure"], [insecure])
        self.assertEqual(before, (folder / "config.json").read_bytes())
        self.assertFalse(json.loads((folder / "client.json").read_text())["outbounds"][0]["tls"]["insecure"])


if __name__ == "__main__": unittest.main()
