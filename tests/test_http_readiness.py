"""Regression tests for delayed Jitsi HTTP readiness after a Swarm deploy.

The check function is exercised with isolated Docker/curl mocks. No network,
Docker daemon, credentials, or real deployment are required by these tests.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'scripts/deploy.sh').read_text()
CHECK = 'check() {' + SCRIPT.split('check() {', 1)[1].split('\nfinalize_tls() {', 1)[0]


class HttpReadinessTests(unittest.TestCase):
    def run_check(self, first_failures=0, wrong_branding=False):
        with tempfile.TemporaryDirectory() as folder:
            body = r'''
set -Eeuo pipefail
DOMAIN=mirea.stream
STACK=mirea
require_root() { :; }
say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
sleep() { :; }
docker() {
    if [[ "$1 $2" == 'stack services' ]]; then
        if [[ "$*" == *'--format'* ]]; then
            printf '%s\n' 'mirea_web 1/1' 'mirea_prosody 1/1' 'mirea_jicofo 1/1' 'mirea_jvb 1/1' 'mirea_nginx 1/1'
        else
            printf '%s\n' 'All five services 1/1'
        fi
    elif [[ "$1 $2" == 'service ps' ]]; then
        printf '%s\n' 'WEB SERVICE DIAGNOSTICS'
    fi
}
curl() {
    local url="${@: -1}" count
    case "$url" in
        */interface_config.js)
            count=$(cat "$STATE_FILE")
            count=$((count + 1))
            printf '%s\n' "$count" > "$STATE_FILE"
            if (( count <= FIRST_FAILURES )); then return 22; fi
            if [[ "$WRONG_BRANDING" == yes ]]; then
                printf '%s\n' 'Jitsi Meet'
            else
                printf '%s\n' 'MIREA Stream'
            fi
            ;;
        */config.js)
            printf '%s\n' "config.dynamicBrandingUrl = '/brand/branding.json';"
            ;;
        *) return 0 ;;
    esac
}
'''
            script = body + '\n' + CHECK + '\ncheck\n'
            state = Path(folder) / 'state'
            state.write_text('0')
            env = os.environ.copy()
            env.update({'STATE_FILE': str(state),
                        'FIRST_FAILURES': str(first_failures),
                        'WRONG_BRANDING': 'yes' if wrong_branding else 'no'})
            result = subprocess.run(['bash', '-c', script], env=env,
                                    text=True, capture_output=True,
                                    timeout=15, check=False)
            return result, int(state.read_text())

    def test_immediately_ready(self):
        result, attempts = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS: 5/5 Swarm tasks', result.stdout)
        self.assertEqual(attempts, 1)

    def test_transient_502_is_retried(self):
        result, attempts = self.run_check(first_failures=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS: 5/5 Swarm tasks', result.stdout)
        self.assertEqual(attempts, 4)

    def test_persistent_502_fails_after_bounded_retries(self):
        result, attempts = self.run_check(first_failures=100)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(attempts, 45)
        self.assertIn('readiness failed', result.stderr)
        self.assertNotIn('PASS:', result.stdout)

    def test_missing_branding_does_not_pass(self):
        result, attempts = self.run_check(wrong_branding=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(attempts, 45)
        self.assertIn('readiness failed', result.stderr)


if __name__ == '__main__':
    unittest.main()
