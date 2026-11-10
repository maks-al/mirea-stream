"""Offline shape checks for the pinned Jitsi -> Swarm conversion."""
import importlib.util
import json
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('renderer', ROOT / 'scripts/render-swarm.py')
renderer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(renderer)


def sample():
    services = {}
    for name in ('web', 'prosody', 'jicofo', 'jvb', 'nginx'):
        svc = {'image': 'example.invalid/' + name + ':pinned',
               'environment': {'PUBLIC_URL': 'https://mirea.stream'},
               'volumes': [{'type': 'bind', 'source': '/tmp/mirea-' + name, 'target': '/config'}]}
        if name != 'nginx':
            svc['read_only'] = True
            svc['tmpfs'] = ['/run:size=16M,mode=1750,exec', '/tmp:size=16M,noexec']
        services[name] = svc
    return {'services': services}


class SwarmTests(unittest.TestCase):
    def test_five_services_and_exec_volumes(self):
        obj = renderer.convert(sample())
        self.assertEqual(len(obj['services']), 5)
        self.assertEqual(len(obj['volumes']), 4)
        for name in ('web', 'prosody', 'jicofo', 'jvb'):
            mounts = obj['services'][name]['volumes']
            self.assertTrue(any(x['target'] == '/run' and x['type'] == 'volume' and
                                x['source'] == 'mirea-run-' + name for x in mounts))
            self.assertTrue(any(x['target'] == '/tmp' and x['type'] == 'tmpfs' for x in mounts))
            self.assertTrue(obj['services'][name]['read_only'])
        self.assertEqual(obj['services']['nginx']['ports'][0]['published'], 80)
        self.assertEqual(obj['services']['jvb']['ports'][0]['protocol'], 'udp')

    def test_missing_exec_run_rejected(self):
        obj = sample()
        obj['services']['web']['tmpfs'] = ['/tmp:size=16M']
        with self.assertRaises(ValueError):
            renderer.convert(obj)

    def test_deployment_parameter_names(self):
        script = (ROOT / 'scripts/deploy.sh').read_text()
        workflow = (ROOT / '.github/workflows/deploy.yml').read_text()
        readme = (ROOT / 'README.md').read_text()
        for key in ('REF', 'NGINX_IMAGE'):
            self.assertIn(key + '=', workflow)
            self.assertIn('${' + key + ':-', script)
        for key in ('PUBLIC_IP', 'MANAGER_IP', 'CONTACT_EMAIL'):
            self.assertIn(key, script)
            self.assertIn(key, readme)
        obsolete_prefix = 'MIR' + 'EA_'
        for name in ('scripts/deploy.sh', '.github/workflows/deploy.yml', 'README.md'):
            self.assertNotIn(obsolete_prefix, (ROOT / name).read_text())

    def test_branding_and_paths(self):
        b = json.loads((ROOT / 'branding/branding.json').read_text())
        self.assertEqual(b['logoImageUrl'], 'https://mirea.stream/brand/logo-header.png')
        self.assertTrue((ROOT / 'branding/assets/background.webp').is_file())
        self.assertTrue((ROOT / 'branding/assets/welcome-background.png').is_file())
        self.assertIn('images/welcome-background.png', (ROOT / 'nginx/default.conf').read_text())
        self.assertIn('config.dynamicBrandingUrl', (ROOT / 'branding/custom-config.js').read_text())
        # Jitsi's welcome heading is translated, not read from APP_NAME.
        self.assertFalse(b['defaultBranding'])
        for lang in ('ru', 'en'):
            translation = json.loads((ROOT / f'branding/assets/labels-{lang}.json').read_text())
            self.assertEqual(translation['welcomepage']['headerTitle'], 'MIREA Stream')
            self.assertEqual(b['labels'][lang], f'https://mirea.stream/brand/labels-{lang}.json')
        for filename in ('logo-header.png', 'logo-color.png', 'logo.svg', 'mark.png', 'mark.svg', 'favicon.ico'):
            self.assertTrue((ROOT / 'branding/assets' / filename).is_file(), filename)
        self.assertTrue((ROOT / 'branding/assets/logo-header.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n'))
        self.assertIn('/brand/logo-header.png', (ROOT / 'branding/custom-interface_config.js').read_text())
        self.assertIn('logo-header.png', (ROOT / 'branding/custom-config.js').read_text())
        self.assertIn('width: 250px', (ROOT / 'branding/assets/welcome.css').read_text())
        self.assertIn('/brand/welcome.css', (ROOT / 'branding/custom-interface_config.js').read_text())
        d = yaml.safe_load((ROOT / '.github/workflows/deploy.yml').read_text())
        self.assertIn('build', d['jobs'])
        self.assertIn('deploy', d['jobs'])
        self.assertIn('branding/**', d[True]['push']['paths'] if True in d else d['on']['push']['paths'])


if __name__ == '__main__':
    unittest.main()
