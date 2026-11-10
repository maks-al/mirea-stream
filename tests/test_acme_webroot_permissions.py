"""Regression tests for ACME HTTP-01 file permissions on restricted-umask VPSes."""
from pathlib import Path
import os
import re
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AcmeWebrootPermissionsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.deploy = (ROOT / 'scripts/deploy.sh').read_text()
        cls.manual = (ROOT / 'docs/MANUAL_DEPLOYMENT.md').read_text()

    def test_public_webroot_is_0755_even_with_umask_077(self):
        match = re.search(r'^prepare_acme_webroot\(\) \{\n.*?^\}', self.deploy, re.M | re.S)
        self.assertIsNotNone(match)
        with tempfile.TemporaryDirectory() as temporary:
            # Demonstrate repair of existing private directories, not only new ones.
            acme = Path(temporary) / 'acme'
            target = acme / '.well-known' / 'acme-challenge'
            target.mkdir(parents=True)
            for directory in (acme, acme / '.well-known', target):
                directory.chmod(0o700)
            script = match.group(0) + '\nROOT="$1"; umask 077; prepare_acme_webroot\n'
            subprocess.run(['bash', '-c', script, '--', temporary], check=True)
            for directory in (acme, acme / '.well-known', target):
                with self.subTest(directory=directory.name):
                    self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o755)

    def test_probed_file_is_readable_before_http_request(self):
        self.assertRegex(self.deploy, r'printf \'mirea-acme-ok.*?\n\s*chmod 644 "\$probe"')
        self.assertLess(self.deploy.index('chmod 644 "$probe"'),
                        self.deploy.index('http://$DOMAIN/.well-known/acme-challenge/${probe##*/}'))
        self.assertIn('rm -f "$probe"', self.deploy)
        self.assertIn('prepare_acme_webroot', self.deploy)
        self.assertIn('chmod 644 /opt/mirea-stream/acme/.well-known/acme-challenge/test.txt', self.manual)

    def test_private_files_not_world_readable(self):
        self.assertIn('umask 077', self.deploy)
        self.assertIn('chmod 600 "$ROOT/.env"', self.deploy)
        self.assertIn('chmod 700 "$ROOT/generated"', self.deploy)
        self.assertNotIn('chmod -R 755 "$ROOT"', self.deploy)

    def test_manual_documents_proven_ubuntu_install(self):
        self.assertIn('apt update -y && apt install -y ca-certificates', self.manual)
        self.assertIn('docker.io docker-compose-v2', self.manual)
        self.assertIn('apt update -y && apt install -y ca-certificates', self.deploy)
        self.assertIn('config.dynamicBrandingUrl', self.deploy)


if __name__ == '__main__':
    unittest.main()
