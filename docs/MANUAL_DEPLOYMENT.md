# Чистовое ручное развёртывание

**Условия:** чистый VPS на Ubuntu, доступ root, домен `mirea.stream` уже указывает на этот VPS. В качестве примера указан прежний IPv4 `213.232.204.246`. **перед началом сверить адрес после переустановки VPS**. Все команды ниже вводятся по **одной физической строке**.

**Важно:** ручной сценарий выполняет те же действия, что `scripts/deploy.sh install`, но отдельными командами - чтобы показать использование Docker, Compose, Swarm, HTTPS и сетей. Для автоматического запуска есть отдельное руководство CD.

## Этап 1 - Docker и зависимости

```bash
apt-get update && apt-get install -y ca-certificates curl gnupg git openssl certbot python3 python3-yaml iproute2
```

```bash
install -m 0755 -d /etc/apt/keyrings
```

```bash
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && chmod a+r /etc/apt/keyrings/docker.asc
```

```bash
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc\n' > /etc/apt/sources.list.d/docker.sources
```

```bash
apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

```bash
systemctl enable --now docker certbot.timer
```

```bash
docker --version && docker compose version
```

## Этап 2 - исходный код, Jitsi и конфигурации

```bash
git clone https://github.com/maks-al/mirea-stream.git /opt/mirea-stream
```

```bash
mkdir -p /opt/mirea-stream/upstream /opt/mirea-stream/generated /opt/mirea-stream/acme/.well-known/acme-challenge
```

```bash
curl -fLsS --retry 3 https://github.com/jitsi/docker-jitsi-meet/archive/refs/tags/stable-11248-2.tar.gz | tar -xz --strip-components=1 -C /opt/mirea-stream/upstream
```

```bash
umask 077 && cp /opt/mirea-stream/upstream/env.example /opt/mirea-stream/.env
```

```bash
sed -i 's@^CONFIG=.*@CONFIG=/opt/mirea-stream/config@;s@^JICOFO_AUTH_PASSWORD=.*@JICOFO_AUTH_PASSWORD='"$(openssl rand -hex 24)"'@;s@^JVB_AUTH_PASSWORD=.*@JVB_AUTH_PASSWORD='"$(openssl rand -hex 24)"'@' /opt/mirea-stream/.env
```

```bash
printf 'PUBLIC_URL=https://mirea.stream\nJVB_ADVERTISE_IPS=%s\nDISABLE_HTTPS=1\nENABLE_HTTP_REDIRECT=0\nENABLE_LETSENCRYPT=0\nENABLE_AUTH=0\nENABLE_GUESTS=0\nENABLE_AUTO_OWNER=1\nDEFAULT_LANGUAGE=ru\nJITSI_IMAGE_VERSION=stable-11248-2\nPROJECT_ROOT=/opt/mirea-stream\nNGINX_IMAGE=mirea-stream-nginx:local\n' "$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)" >> /opt/mirea-stream/.env
```

```bash
chmod 600 /opt/mirea-stream/.env && install -d -m 700 /opt/mirea-stream/generated
```

```bash
mkdir -p /opt/mirea-stream/config/web /opt/mirea-stream/config/storage/web /opt/mirea-stream/config/storage/transcripts /opt/mirea-stream/config/prosody/config /opt/mirea-stream/config/prosody/prosody-plugins-custom /opt/mirea-stream/config/storage/prosody /opt/mirea-stream/config/jicofo /opt/mirea-stream/config/jvb /opt/mirea-stream/config/tmp/web-load-test
```

```bash
chown -R 1000:1000 /opt/mirea-stream/config
```

```bash
install -m 644 -o 1000 -g 1000 /opt/mirea-stream/branding/custom-config.js /opt/mirea-stream/config/web/custom-config.js && install -m 644 -o 1000 -g 1000 /opt/mirea-stream/branding/custom-interface_config.js /opt/mirea-stream/config/web/custom-interface_config.js
```

## Этап 3 - первый сертификат HTTPS

Сейчас порты 80/443 должны быть свободны. При наличии почты можно добавить `--email АДРЕС` вместо `--register-unsafely-without-email`.

```bash
certbot certonly --standalone --preferred-challenges http --agree-tos --non-interactive --register-unsafely-without-email -d mirea.stream
```

```bash
certbot certificates
```

## Этап 4 - временное ручное развёртывание Compose

```bash
docker compose --project-directory /opt/mirea-stream --env-file /opt/mirea-stream/.env -f /opt/mirea-stream/upstream/docker-compose.yml -f /opt/mirea-stream/docker-compose.override.yml config -q
```

```bash
docker compose --project-directory /opt/mirea-stream --env-file /opt/mirea-stream/.env -f /opt/mirea-stream/upstream/docker-compose.yml -f /opt/mirea-stream/docker-compose.override.yml up -d --build
```

```bash
docker compose --project-directory /opt/mirea-stream --env-file /opt/mirea-stream/.env -f /opt/mirea-stream/upstream/docker-compose.yml -f /opt/mirea-stream/docker-compose.override.yml ps
```

```bash
curl -4fsSI https://mirea.stream/ && curl -4fsSI https://mirea.stream/brand/logo.svg && curl -4fsSI https://mirea.stream/brand/background.webp && curl -4fsSI https://mirea.stream/images/welcome-background.png
```

## Этап 5 - перенос в Swarm

```bash
docker compose --project-directory /opt/mirea-stream --env-file /opt/mirea-stream/.env -f /opt/mirea-stream/upstream/docker-compose.yml -f /opt/mirea-stream/docker-compose.override.yml down
```

```bash
docker swarm init --advertise-addr "$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
```

```bash
bash /opt/mirea-stream/scripts/setup-swarm-volumes.sh
```

```bash
docker compose --project-directory /opt/mirea-stream --env-file /opt/mirea-stream/.env -f /opt/mirea-stream/upstream/docker-compose.yml -f /opt/mirea-stream/docker-compose.override.yml config --format json > /opt/mirea-stream/generated/compose-resolved.json
```

```bash
python3 /opt/mirea-stream/scripts/render-swarm.py /opt/mirea-stream/generated/compose-resolved.json /opt/mirea-stream/generated/stack.swarm.yml
```

```bash
docker stack config --compose-file /opt/mirea-stream/generated/stack.swarm.yml > /dev/null && echo 'Swarm config OK'
```

```bash
docker stack deploy --resolve-image never --compose-file /opt/mirea-stream/generated/stack.swarm.yml mirea
```

```bash
docker node ls && docker stack services mirea && docker stack ps mirea
```

```bash
curl -4fsSI https://mirea.stream/ && curl -4fsSI https://mirea.stream/config.js
```

## Этап 6 - автоматическое продление HTTPS и резервирование

```bash
printf 'mirea-acme-ok\n' > /opt/mirea-stream/acme/.well-known/acme-challenge/test.txt && curl -4fsS http://mirea.stream/.well-known/acme-challenge/test.txt
```

```bash
rm /opt/mirea-stream/acme/.well-known/acme-challenge/test.txt
```

```bash
certbot reconfigure --cert-name mirea.stream --webroot -w /opt/mirea-stream/acme
```

```bash
install -D -m 755 /opt/mirea-stream/scripts/renew-hook.sh /etc/letsencrypt/renewal-hooks/deploy/mirea-nginx-reload.sh
```

```bash
systemctl enable --now certbot.timer && certbot renew --cert-name mirea.stream --dry-run
```

```bash
bash /opt/mirea-stream/scripts/backup.sh && ls -lh /root/mirea-stream-backups/
```

## Этап 7 - ручная проверка и снятие итоговых показателей

```bash
bash /opt/mirea-stream/scripts/deploy.sh check
```

```bash
docker stats --no-stream
```

```bash
curl -6fsSI https://mirea.stream/ && curl -4fsSI https://mirea.stream/brand/branding.json
```