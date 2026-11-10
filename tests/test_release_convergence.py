"""Offline regression tests for a Swarm release (private registry, rollback, stale HTTP)."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'scripts/deploy.sh').read_text()
VERIFY = 'verify_nginx_release() {' + SOURCE.split('verify_nginx_release() {', 1)[1].split('\ncheck() {', 1)[0]


class ReleaseConvergenceTests(unittest.TestCase):
    def test_prepull_before_stack_change(self):
        swarm = SOURCE.split('swarm_deploy() {', 1)[1].split('\nverify_nginx_release() {', 1)[0]
        self.assertIn('docker pull "$desired_image" || fail', swarm)
        self.assertLess(swarm.index('docker pull "$desired_image"'), swarm.index('docker stack deploy'))
        self.assertIn('verify_nginx_release', swarm)

    def run_verify(self, scenario):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp, 'nginx', 'default.conf')
            config.parent.mkdir()
            config.write_text('server { add_header X-Mirea-Release "v3" always; }\n'
                              '    add_header X-Mirea-Release "v3" always;\n')
            counter = Path(temp, 'counter')
            counter.write_text('0')
            stub = r'''
set -Eeuo pipefail
STACK=mirea
DOMAIN=mirea.stream
ROOT="$TEST_ROOT"
require_root() { :; }
say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
env_value() { printf '%s' "ghcr.io/maks-al/mirea-nginx:target123"; }
sleep() { :; }
docker() {
    if [[ "$1 $2" == 'service inspect' ]]; then
        local format="${@: -1}" n
        if [[ "$format" == *UpdateStatus.State* ]]; then
            n="$(cat "$COUNTER_FILE")"
            printf '%s\n' "$((n+1))" > "$COUNTER_FILE"
            if [[ "$SCENARIO" == rollback ]]; then printf 'rollback_completed\n'; return; fi
            if [[ "$SCENARIO" == transient && "$n" -lt 2 ]]; then printf 'updating\n'; return; fi
            printf 'completed\n'
        elif [[ "$format" == *ContainerSpec.Image* ]]; then
            if [[ "$SCENARIO" == stale ]]; then echo 'ghcr.io/maks-al/mirea-nginx:old';
            else echo 'ghcr.io/maks-al/mirea-nginx:target123@sha256:0123456789abcdef'; fi
        else printf '{}\n'; fi
    elif [[ "$1 $2" == 'service ls' ]]; then printf '1/1\n'
    elif [[ "$1" == ps ]]; then
        if [[ "$SCENARIO" == stale ]]; then echo 'ghcr.io/maks-al/mirea-nginx:old';
        else echo 'ghcr.io/maks-al/mirea-nginx:target123@sha256:0123456789abcdef'; fi
    elif [[ "$1 $2" == 'service ps' ]]; then printf 'SERVICE-PS-DIAGNOSTICS\n'; fi
}
curl() { if [[ "$SCENARIO" == stale || "$SCENARIO" == wrong_header ]]; then printf 'X-Mirea-Release: v2-brand\r\n'; else printf 'X-Mirea-Release: v3\r\n'; fi; }
'''
            environment = os.environ.copy()
            environment.update(TEST_ROOT=temp, COUNTER_FILE=str(counter), SCENARIO=scenario)
            result = subprocess.run(['bash', '-c', stub + '\n' + VERIFY + '\nverify_nginx_release\n'],
                                    env=environment, text=True, capture_output=True, timeout=15, check=False)
            return result, int(counter.read_text())

    def test_current_release_accepted(self):
        result, tries = self.run_verify('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Release verified:', result.stdout)
        self.assertEqual(tries, 1)

    def test_pending_swarm_update_is_waited_for(self):
        result, tries = self.run_verify('transient')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(tries, 3)

    def test_auto_rollback_is_rejected(self):
        result, tries = self.run_verify('rollback')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rollback_completed', result.stderr)
        self.assertIn('SERVICE-PS-DIAGNOSTICS', result.stdout)
        self.assertEqual(tries, 1)

    def test_wrong_http_release_never_passes(self):
        result, tries = self.run_verify('wrong_header')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not activated', result.stderr)
        self.assertEqual(tries, 60)

    def test_stale_old_release_never_passes(self):
        result, tries = self.run_verify('stale')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not activated', result.stderr)
        self.assertEqual(tries, 60)


if __name__ == '__main__':
    unittest.main()
