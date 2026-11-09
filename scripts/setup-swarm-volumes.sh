#!/usr/bin/env bash
# Create the four executable tmpfs-backed /run volumes required by Jitsi s6.
# Safe to run again: existing volumes are inspected, not overwritten.
set -euo pipefail
for role in web prosody jicofo jvb; do
  name="mirea-run-${role}"
  if docker volume inspect "$name" >/dev/null 2>&1; then
    driver="$(docker volume inspect "$name" --format '{{.Driver}}')"
    opts="$(docker volume inspect "$name" --format '{{index .Options "o"}}')"
    kind="$(docker volume inspect "$name" --format '{{index .Options "type"}}')"
    device="$(docker volume inspect "$name" --format '{{index .Options "device"}}')"
    if [[ "$driver" != local || "$kind" != tmpfs || "$device" != tmpfs || ",$opts," != *",exec,"* ]]; then
      echo "ERROR: $name has wrong options. Do not overwrite an active volume." >&2
      exit 1
    fi
    echo "Existing OK: $name"
  else
    docker volume create --driver local --opt type=tmpfs --opt device=tmpfs --opt o=exec,nosuid,nodev,size=32m,mode=1750,uid=1000,gid=1000 "$name"
  fi
done
