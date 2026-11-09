#!/usr/bin/env python3
"""Build the mirea-stream Swarm stack from resolved official Jitsi Compose JSON.

Supports the pinned Jitsi stable-11248-2 release and exactly five services.
Docker Swarm cannot express tmpfs 'exec' in the stack file. Jitsi's s6-overlay
requires an executable /run, so each Jitsi service uses a separately prepared
external Docker local volume backed by tmpfs mounted with exec.

Use scripts/setup-swarm-volumes.sh to prepare those volumes first.
The output embeds Jitsi passwords: keep generated/ private and out of Git.
"""

import argparse
import json
import os
import re
from pathlib import Path

import yaml

SERVICES = ("web", "prosody", "jicofo", "jvb", "nginx")
JITSI_SERVICES = ("web", "prosody", "jicofo", "jvb")
SIZE_RE = re.compile(r"^(\d+)([kKmMgG]?)$")


def parse_tmpfs(spec):
    """Convert non-executable Compose tmpfs (e.g., /tmp) to Swarm mount."""
    if not isinstance(spec, str):
        raise ValueError(f"Unsupported tmpfs entry: {spec!r}")
    parts = spec.split(":", 1)
    target = parts[0]
    if not target.startswith("/"):
        raise ValueError(f"tmpfs target must be an absolute path: {spec}")
    opts = {}
    for part in (parts[1].split(",") if len(parts) > 1 else []):
        if "=" in part:
            key, value = part.split("=", 1)
            opts[key] = value
        elif part not in ("", "noexec", "nosuid", "nodev"):
            raise ValueError(f"Unsupported tmpfs flag {part!r} in {spec}")
    if "exec" in opts:
        raise ValueError("tmpfs exec option cannot be represented in Swarm")
    if target == "/run":
        raise ValueError("/run must be mapped to executable external volume")
    mount = {"type": "tmpfs", "target": target}
    tmpfs_options = {}
    if "size" in opts:
        match = SIZE_RE.fullmatch(opts["size"])
        if not match:
            raise ValueError(f"Invalid tmpfs size {opts['size']!r}")
        factor = {"": 1, "k": 1024, "m": 1024**2, "g": 1024**3}[match[2].lower()]
        tmpfs_options["size"] = int(match[1]) * factor
    if "mode" in opts:
        tmpfs_options["mode"] = int(opts["mode"], 8)
    if tmpfs_options:
        mount["tmpfs"] = tmpfs_options
    return mount


def convert(model):
    if set(model.get("services", {})) != set(SERVICES):
        raise ValueError("Expected exactly these services: " + ", ".join(SERVICES))

    stack = {
        "version": "3.8",
        "services": {},
        "networks": {"backend": {"driver": "overlay"}},
        "volumes": {f"mirea-run-{name}": {"external": True} for name in JITSI_SERVICES},
    }

    for name in SERVICES:
        original = model["services"][name]
        if not original.get("image"):
            raise ValueError(f"Missing image for {name}")
        svc = {
            "image": original["image"],
            "networks": ["backend"],
            "deploy": {
                "replicas": 1,
                "restart_policy": {"condition": "any", "delay": "5s"},
                "update_config": {
                    "parallelism": 1,
                    "order": "stop-first",
                    "failure_action": "rollback",
                },
            },
        }
        env = {k: v for k, v in (original.get("environment") or {}).items() if v is not None}
        if env:
            svc["environment"] = env
        if original.get("read_only"):
            svc["read_only"] = True

        mounts = []
        for volume in original.get("volumes", []) or []:
            if volume.get("type") != "bind":
                raise ValueError(f"Unsupported persistent mount in {name}: {volume!r}")
            src = volume.get("source", "")
            if not src.startswith("/") or src == "/":
                raise ValueError(f"Invalid bind source in {name}: {src!r}")
            mount = {"type": "bind", "source": src, "target": volume["target"]}
            if volume.get("read_only"):
                mount["read_only"] = True
            mounts.append(mount)

        run_mounts = 0
        for item in original.get("tmpfs", []) or []:
            if not isinstance(item, str):
                raise ValueError(f"Unsupported Compose tmpfs in {name}: {item!r}")
            target = item.split(":", 1)[0]
            if target == "/run":
                if name not in JITSI_SERVICES:
                    raise ValueError("Unexpected /run tmpfs on service " + name)
                run_mounts += 1
                mounts.append({"type": "volume", "source": f"mirea-run-{name}", "target": "/run"})
            else:
                mounts.append(parse_tmpfs(item))
        if name in JITSI_SERVICES and run_mounts != 1:
            raise ValueError(f"Expected one /run tmpfs from upstream for {name}; got {run_mounts}")
        if mounts:
            svc["volumes"] = mounts

        if name == "prosody":
            xmpp_host = env.get("XMPP_SERVER") or "xmpp.meet.jitsi"
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", xmpp_host):
                raise ValueError("Invalid XMPP_SERVER: " + xmpp_host)
            svc["networks"] = {"backend": {"aliases": [xmpp_host, "prosody"]}}
        elif name == "nginx":
            svc["ports"] = [
                {"target": 80, "published": 80, "protocol": "tcp", "mode": "host"},
                {"target": 443, "published": 443, "protocol": "tcp", "mode": "host"},
            ]
        elif name == "jvb":
            if str(env.get("JVB_PORT", "10000")) != "10000":
                raise ValueError("This project requires JVB_PORT=10000")
            svc["ports"] = [
                {"target": 10000, "published": 10000, "protocol": "udp", "mode": "host"}
            ]
        stack["services"][name] = svc
    return stack


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("compose_json", help="Output of docker compose config --format json")
    parser.add_argument("output", help="Private path, e.g. generated/stack.swarm.yml")
    args = parser.parse_args()
    model = json.loads(Path(args.compose_json).read_text(encoding="utf-8"))
    stack = convert(model)
    destination = Path(args.output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        yaml.safe_dump(stack, file, sort_keys=False, allow_unicode=True, default_flow_style=False)
    destination.chmod(0o600)
    print(f"Swarm manifest ready: {destination} ({len(SERVICES)} services; private file)")


if __name__ == "__main__":
    main()
