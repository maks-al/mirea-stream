"""Ensure every fixed Jitsi bind source exists on clean Swarm installations."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
ROLES = ('web', 'prosody', 'jicofo', 'jvb')


class CleanInstallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = (ROOT / 'scripts/deploy.sh').read_text()
        cls.workflow = (ROOT / '.github/workflows/deploy.yml').read_text()

    def test_all_upstream_custom_ca_mount_sources_created(self):
        sources = self.script.split('sources() {', 1)[1].split('certificate() {', 1)[0]
        for role in ROLES:
            with self.subTest(role=role):
                self.assertIn(f'"$ROOT/config/{role}/custom-ca"', sources)
        # The existing ownership adjustment must happen after creation.
        self.assertLess(sources.index('"$ROOT/config/jvb/custom-ca"'),
                        sources.index('chown -R 1000:1000 "$ROOT/config"'))

    def test_no_rollback_when_install_has_no_previous_spec(self):
        block = self.workflow.split('Run unified installer/updater on VPS', 1)[1]
        self.assertIn('if [[ "$mode" != install ]]; then', block)
        self.assertIn('PreviousSpec', block)
        self.assertLess(block.index('if [[ "$mode" != install ]]; then'),
                        block.index('docker service rollback mirea_nginx'))


if __name__ == '__main__':
    unittest.main()
