# Автоматизированная установка и обновление и GitHub Actions

## Принцип

Один и тот же `scripts/deploy.sh` используется вручную на VPS и в CD. Workflow собирает Nginx со всеми материалами темы, проверяет скрипты, публикует SHA-версионированный образ в GHCR, после чего по SSH выполняет `deploy.sh install`, `update` или `auto` на сервере. При обновлении создаётся резервная копия, сохраняются `.env` и Certbot, заново генерируется Swarm-манифест, проводится проверка пяти сервисов и HTTPS.

## Секреты GitHub Actions

Для тестового VPS безопаснее использовать отдельную пару SSH-ключей. Ключ должен подходить пользователю, от имени которого разрешено выполнение root-команд Docker/Certbot (но для тестовой VPS допустим `root`). На VPS надо выполнить:

```bash
install -d -m 700 /root/.ssh && ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/mirea-actions -C github-actions-mirea
```

```bash
cat /root/.ssh/mirea-actions.pub >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
```

```bash
cat /root/.ssh/mirea-actions
```

```bash
awk '{print "213.232.204.246 " $1 " " $2}' /etc/ssh/ssh_host_ed25519_key.pub
```

Внешний IP тестового VPS, на котором разворачивался Mirea Stream, указан в Secrets. Если внешний IP поменялся, нужно заменить `213.232.204.246` на новый адрес.

В [Secrets for Actions](https://github.com/maks-al/mirea-stream/settings/secrets/actions) требуется указать:

| Имя | Источник |
|---|---|
| `DEPLOY_HOST` | IPv4 сервера |
| `DEPLOY_USER` | `root` |
| `DEPLOY_SSH_KEY` | Приватный ключ `/root/.ssh/mirea-actions` (весь текст) |
| `DEPLOY_KNOWN_HOSTS` | Строка из `ssh_host_ed25519_key.pub` с префиксом IP |

Важное условие GitHub Actions: при публичном репозитории GHCR-образ может по умолчанию оказаться приватным. Workflow передаёт временный `GITHUB_TOKEN` на VPS по защищённому SSH-вводу в `docker login ghcr.io`, не печатает токен в лог. Для чистого VPS сначала устанавливает Docker через тот же `deploy.sh packages`.

## Ограничения проверки

`curl 200` проверяет HTTPS и отдачу JS/логотипа, но **не проверяет звук/видео**. Тест WebRTC проводится в браузере с несколькими участниками, также проверяется модерация первым участником, видео, звук, демонстрация экрана.

## Аварийное восстановление

- `docker stack ps mirea --no-trunc` - состояния задач.
- `docker service logs --tail 100 mirea_web` - журнал web.
- `docker service logs --tail 100 mirea_nginx` - журнал прокси.
- `docker service rollback mirea_nginx` - откат последнего обновления прокси (при наличии предыдущей версии).
- `bash /opt/mirea-stream/scripts/backup.sh` - резервная копия текущих постоянных файлов.