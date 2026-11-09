#!/usr/bin/env bash
# Copy to /etc/letsencrypt/renewal-hooks/deploy/mirea-nginx-reload.sh
set -euo pipefail
command -v docker >/dev/null || exit 0
cid="$(docker ps -q --filter label=com.docker.swarm.service.name=mirea_nginx | head -n 1)"
if [[ -z "$cid" ]]; then
  cid="$(docker ps -q --filter label=com.docker.compose.service=nginx | head -n 1)"
fi
if [[ -n "$cid" ]]; then
  docker exec "$cid" nginx -s reload
fi
