#!/usr/bin/env python3
"""Convert a RESOLVED Docker Compose JSON model to a small Swarm v3.8 stack.

Run only with the pinned upstream Jitsi release + our overlay. This script
preserves all Jitsi environment variables, bind mounts and rootless /run,/tmp
mounts; it is deliberately not a generic Compose-to-Swarm converter.
The output includes secrets, so it must never enter version control.
"""
import argparse
import json
import os
import re
from pathlib import Path
import yaml

SERVICES = ('web', 'prosody', 'jicofo', 'jvb', 'nginx')
SIZE_RE = re.compile(r'^(\d+)([kKmMgG]?)$')


def parse_tmpfs(spec):
    # Expected form: /run:size=32M,mode=1750,exec
    if isinstance(spec, dict):
        raise ValueError('Неожиданная форма tmpfs; проверьте версию Compose')
    parts = str(spec).split(':', 1)
    target = parts[0]
    opts = {}
    for pair in (parts[1].split(',') if len(parts) > 1 else []):
        if '=' in pair:
            k, v = pair.split('=', 1)
            opts[k] = v
    mount = {'type': 'tmpfs', 'target': target}
    tmp = {}
    if 'size' in opts:
        m = SIZE_RE.fullmatch(opts['size'])
        if not m:
            raise ValueError('Неизвестный формат размера tmpfs: ' + opts['size'])
        scale = {'': 1, 'k': 1024, 'm': 1024**2, 'g': 1024**3}[m[2].lower()]
        tmp['size'] = int(m[1]) * scale
    if 'mode' in opts:
        tmp['mode'] = int(opts['mode'], 8)
    if tmp:
        mount['tmpfs'] = tmp
    return mount


def convert(model):
    if set(model.get('services', {})) != set(SERVICES):
        raise ValueError('Ожидается ровно 5 сервисов: ' + ', '.join(SERVICES))
    dest = {'version': '3.8', 'services': {}, 'networks': {'backend': {'driver': 'overlay'}}}
    for name in SERVICES:
        old = model['services'][name]
        if not old.get('image'):
            raise ValueError(f'Не указан image у {name}')
        svc = {
            'image': old['image'],
            'networks': ['backend'],
            'deploy': {
                'replicas': 1,
                'restart_policy': {'condition': 'any', 'delay': '5s'},
                'update_config': {'parallelism': 1, 'order': 'stop-first', 'failure_action': 'rollback'},
            },
        }
        env = {k: v for k, v in (old.get('environment') or {}).items() if v is not None}
        if env:
            svc['environment'] = env
        if old.get('read_only'):
            svc['read_only'] = True
        mounts = []
        for v in old.get('volumes', []):
            if v.get('type') != 'bind':
                raise ValueError(f'Неизвестный вид постоянного mount для {name}: {v!r}')
            if not v.get('source', '').startswith('/'):
                raise ValueError(f'Не абсолютный bind path для {name}: {v!r}')
            mount = {
                'type': 'bind', 'source': v['source'], 'target': v['target'],
            }
            if v.get('read_only'):
                mount['read_only'] = True
            mounts.append(mount)
        for t in old.get('tmpfs', []) or []:
            mounts.append(parse_tmpfs(t))
        if mounts:
            svc['volumes'] = mounts
        if name == 'prosody':
            fqdn = env.get('XMPP_SERVER') or 'xmpp.meet.jitsi'
            if not re.fullmatch(r'[A-Za-z0-9_.-]+', fqdn):
                raise ValueError('Некорректный XMPP_SERVER: ' + fqdn)
            svc['networks'] = {'backend': {'aliases': [fqdn, 'prosody']}}
        if name == 'nginx':
            svc['ports'] = [
                {'target': 80, 'published': 80, 'protocol': 'tcp', 'mode': 'host'},
                {'target': 443, 'published': 443, 'protocol': 'tcp', 'mode': 'host'},
            ]
        if name == 'jvb':
            svc['ports'] = [{'target': 10000, 'published': 10000, 'protocol': 'udp', 'mode': 'host'}]
            if str(env.get('JVB_PORT', '10000')) != '10000':
                raise ValueError('В данном проекте JVB_PORT должен быть 10000')
        dest['services'][name] = svc
    return dest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('compose_json', help='docker compose config --format json output')
    ap.add_argument('output', help='Private output file, e.g. generated/stack.swarm.yml')
    args = ap.parse_args()
    src = json.loads(Path(args.compose_json).read_text())
    out = convert(src)
    target = Path(args.output)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as fh:
        yaml.safe_dump(out, fh, sort_keys=False, allow_unicode=True, default_flow_style=False)
    target.chmod(0o600)
    print(f'Создан закрытый Swarm-файл: {target} (5 сервисов). Не публиковать: содержит пароли.')


if __name__ == '__main__':
    main()
