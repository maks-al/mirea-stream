#!/usr/bin/env bash
set -euo pipefail
cd /opt/mirea-stream
printf '%s\n' '== HTTPS =='
curl --fail --silent --show-error --head --max-time 15 https://mirea.stream/ | sed -n '1,14p'
printf '%s\n' '== WebSocket endpoint (проверяем HTTPS, а не WS-сессию) =='
curl --silent --show-error --output /dev/null --write-out 'HTTP %{http_code}\n' --max-time 10 https://mirea.stream/xmpp-websocket
printf '%s\n' '== Сервисы Swarm =='
docker stack services mirea 2>/dev/null || true
printf '%s\n' '== Контейнеры =='
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
