# Автоматизированная установка и обновление — GitHub Actions

## Принцип

Один и тот же `scripts/deploy.sh` используется вручную на VPS и в CD. Workflow собирает Nginx со всеми материалами темы, проверяет скрипты, публикует SHA-версионированный образ в GHCR, после чего по SSH выполняет `deploy.sh install`, `update` или `auto` на сервере. При обновлении создаётся резервная копия, сохраняются `.env` и Certbot, заново генерируется Swarm-манифест, проводится проверка пяти сервисов и HTTPS. Нет второго VPS, нет внешней СУБД и нет собственного бэкенда.

## Защита от преждевременного CD

- Пока проводишь ручной этап, **не включай** GitHub Actions Variable `DEPLOY_ENABLED` (или установи `false`): `push` запустит только CI + публикацию образа.
- После ручного этапа можно запустить **Actions → MIREA Stream CI/CD → Run workflow → mode=update**.
- Для подтверждения полностью автоматизированной установки **после повторной очистки VPS** используй Run workflow → `mode=install`.
- Когда всё проверено, в Repository Settings → Secrets and variables → Actions → **Variables** добавь `DEPLOY_ENABLED=true`. Тогда следующие push в `main`, затрагивающие проект, автоматически выполняют обновление (`auto`).

## Секреты GitHub Actions

Для тестового VPS безопаснее использовать отдельную пару SSH-ключей. Ключ должен подходить пользователю, от имени которого разрешено выполнение root-команд Docker/Certbot (для лабораторной VPS допустим `root`). На чистом VPS:

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

Если внешний IP поменялся, замени `213.232.204.246` в значении и Secrets. Значение `DEPLOY_KNOWN_HOSTS` сверяй с публичным ключом именно твоего сервера, а не с неаутентифицированным `ssh-keyscan`.

В [Secrets for Actions](https://github.com/maks-al/mirea-stream/settings/secrets/actions) укажи:

| Имя | Источник |
|---|---|
| `DEPLOY_HOST` | IPv4 сервера |
| `DEPLOY_USER` | `root` |
| `DEPLOY_SSH_KEY` | Приватный ключ `/root/.ssh/mirea-actions` (весь текст) |
| `DEPLOY_KNOWN_HOSTS` | Строка из `ssh_host_ed25519_key.pub` с префиксом IP |

Важное условие GitHub Actions: при публичном репозитории GHCR-образ может по умолчанию оказаться приватным. Workflow передаёт временный `GITHUB_TOKEN` на VPS по защищённому SSH-вводу в `docker login ghcr.io`, не печатает токен в лог. Для чистого VPS сначала устанавливает Docker через тот же `deploy.sh packages`.

## Демонстрация в отчёте

1. CI: проверка Python/Bash, Nginx и сборка образа с тегом SHA.
2. CD: `workflow_dispatch` → `install` на чистой ОС; все пять сервисов `1/1`.
3. CD: изменить `X-Mirea-Release` в `nginx/default.conf`, закоммитить в main при `DEPLOY_ENABLED=true`; новая версия обновляется автоматически.
4. Проверка: `docker service inspect mirea_nginx --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'` показывает новую версию GHCR, `curl -I https://mirea.stream` возвращает обновлённый заголовок, остальные сервисы `1/1`.
5. Из GitHub Actions сохранить снимок зелёного workflow с **выполненными**, а не пропущенными шагами деплоя.

## Ограничения проверки

`curl 200` проверяет HTTPS и отдачу JS/логотипа, но **не проверяет звук/видео**. Приёмка WebRTC проводится в браузере: два и три участника, модерация первым участником, видео, звук, демонстрация экрана. Результат можно записать таблицей без изображений участников.

## Аварийное восстановление

- `docker stack ps mirea --no-trunc` — состояния задач.
- `docker service logs --tail 100 mirea_web` — журнал web.
- `docker service logs --tail 100 mirea_nginx` — журнал прокси.
- `docker service rollback mirea_nginx` — откат последнего обновления прокси (при наличии предыдущей версии).
- `bash /opt/mirea-stream/scripts/backup.sh` — резервная копия текущих постоянных файлов.

Никогда не использовать `docker system prune --volumes`, `docker volume prune`, массовое удаление `/opt/mirea-stream/config` или `/etc/letsencrypt` для устранения проблем. В одноузловом Swarm реплика 1/1 не является доказательством отказоустойчивости к потере узла.
