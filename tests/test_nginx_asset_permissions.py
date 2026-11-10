"""Regression guard for permission-denied responses on public brand assets."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class NginxAssetPermissionsTests(unittest.TestCase):
    def test_docker_image_fixes_read_permissions_after_copy(self):
        dockerfile = (ROOT / 'nginx' / 'Dockerfile').read_text()
        asset_copy = 'COPY branding/assets/ /usr/share/nginx/html/brand/'
        branding_copy = ('COPY branding/branding.json '
                         '/usr/share/nginx/html/brand/branding.json')
        fix = 'RUN chmod -R a+rX /usr/share/nginx/html/brand'
        self.assertIn(asset_copy, dockerfile)
        self.assertIn(branding_copy, dockerfile)
        self.assertIn(fix, dockerfile)
        self.assertGreater(dockerfile.index(fix), dockerfile.index(asset_copy))
        self.assertGreater(dockerfile.index(fix), dockerfile.index(branding_copy))

    def test_required_brand_files_exist(self):
        for asset in ('logo-header.png', 'welcome.css', 'labels-ru.json',
                      'labels-en.json', 'favicon.ico'):
            with self.subTest(asset=asset):
                self.assertTrue((ROOT / 'branding/assets' / asset).is_file())
        self.assertTrue((ROOT / 'branding/branding.json').is_file())


if __name__ == '__main__':
    unittest.main()
