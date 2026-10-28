"""No-network regression smoke checks for the V2.1 installer."""
from pathlib import Path
import subprocess
import unittest

SCRIPT=Path(__file__).resolve().parents[1] / 'install.sh'

class ScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source=SCRIPT.read_text(encoding='utf-8')

    def test_bash_syntax(self):
        subprocess.run(['bash','-n',str(SCRIPT)],check=True)
    def test_help_non_destructive(self):
        r=subprocess.run(['bash',str(SCRIPT),'--help'],capture_output=True,text=True,check=True)
        self.assertIn('diagnose',r.stdout)
        self.assertIn('selftest',r.stdout)
    def test_version(self):
        self.assertIn('SCRIPT_VERSION=2.1.0',self.source)
    def test_client_pipeline(self):
        for feature in ('self_test() (', 'socks5h://127.0.0.1:', "'password':key", "'flow':'xtls-rprx-vision'", 'ForceIPv4'):
            self.assertIn(feature,self.source)
    def test_dns_and_log_and_target(self):
        for feature in ('https+local://1.1.1.1/dns-query','maskAddress\':\'quarter','reality_probe()','choose_dns()','choose_log()'):
            self.assertIn(feature,self.source)
    def test_old_node_is_not_overwritten(self):
        self.assertIn("'检测到已有独立节点，拒绝覆盖",self.source)
        self.assertIn("'外部测试：使用具备 IPv6 的客户端访问",self.source)
    def test_no_unicode_var_collision(self):
        import re
        self.assertFalse(re.findall(r'\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]',self.source))

if __name__=='__main__':
    unittest.main()
