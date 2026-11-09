#!/usr/bin/env bash
set -euo pipefail
echo '== Ubuntu =='
cat /etc/os-release | grep -E '^(NAME|VERSION)='
echo '== Ресурсы =='
free -h | head -n 2
df -h / | tail -n 1
nproc
echo '== Адреса DNS =='
getent ahostsv4 mirea.stream | awk '{print $1}' | sort -u || true
getent ahostsv6 mirea.stream | awk '{print $1}' | sort -u || true
echo '== Слушающие сокеты (не удалять чужие службы!) =='
sudo ss -lntup | grep -E ':(80|443|10000)[[:space:]]' || true
echo '== Docker =='
if command -v docker >/dev/null; then docker --version; docker compose version || true; docker info --format 'Swarm={{.Swarm.LocalNodeState}}' || true; else echo 'Docker не установлен'; fi
echo '== Существующие контейнеры =='
if command -v docker >/dev/null; then sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' || true; fi
