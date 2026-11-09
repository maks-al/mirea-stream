#!/usr/bin/env bash
# Run as root. Backup contains passwords and private TLS keys: protect it.
set -euo pipefail
[[ $(id -u) -eq 0 ]] || { echo 'Запустить через sudo' >&2; exit 1; }
[[ -d /opt/mirea-stream/config && -f /opt/mirea-stream/.env ]] || { echo 'Проект не найден' >&2; exit 1; }
mkdir -p /root/mirea-stream-backups
chmod 700 /root/mirea-stream-backups
filename="/root/mirea-stream-backups/mirea-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
tar -czf "$filename" -C /opt/mirea-stream .env config nginx docker-compose.override.yml -C /etc letsencrypt
chmod 600 "$filename"
echo "Резервная копия: $filename"
