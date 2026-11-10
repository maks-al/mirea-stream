Платформа видеоконференций на основе **Jitsi Meet `stable-11248-2`**. Предназначен для разворачивания на VPS (желательно Ubuntu 24.04 LTS), с привязанным доменом `mirea.stream`, после чего устанавливаются 5 сервисов/контейнеров: `web`, `prosody`, `jicofo`, `jvb` и `nginx`.

## Режимы

| Команда | Назначение |
|---|---|
| `bash scripts/deploy.sh install` | Полная автоматическая установка на чистом Ubuntu 24.04 VPS |
| `bash scripts/deploy.sh update` | Обновление существующего Swarm-стека с резервной копией |
| `bash scripts/deploy.sh auto` | Выбирает установку или обновление в зависимости от наличия `.env` |
| `bash scripts/deploy.sh check` | Проверка пяти задач, HTTPS и файлов темы |
| `bash scripts/deploy.sh packages` | Подготовка Ubuntu, Docker и Certbot |
| `bash scripts/deploy.sh sources` | Получение Jitsi и настройка `.env` + брендинга |
| `bash scripts/deploy.sh certificate` | Первый сертификат Let's Encrypt в режиме standalone |
| `bash scripts/deploy.sh compose` | Временный запуск Docker Compose для ручной демонстрации |
| `bash scripts/deploy.sh swarm` | Переход с Compose на одноузловой Swarm |
| `bash scripts/deploy.sh tls` | Webroot-продление и тест сертификата |

Запускать от `root`, из каталога `/opt/mirea-stream`. Автоматический установщик может сам клонировать этот GitHub-репозиторий в директорию.

**Пошаговая ручная установка со снимками экрана:** [docs/MANUAL_DEPLOYMENT.md](docs/MANUAL_DEPLOYMENT.md).

**Автоматизация и CD:** [docs/CD_AND_TESTS.md](docs/CD_AND_TESTS.md).

### Быстрый старт на свежем VPS

Предварительно привязать A/AAAA записи домена к айпи VPS, обеспечить доступность портов 80/TCP, 443/TCP и 10000/UDP, обязательно подключиться по SSH. Не открывать порты кластера Docker Swarm в интернет (они только локальные).

```bash
curl -fsSL https://raw.githubusercontent.com/maks-al/mirea-stream/main/scripts/deploy.sh -o /root/mirea-deploy.sh
```

```bash
bash /root/mirea-deploy.sh install
```

### Параметры

При необходимости можно задать переменные окружения до вызова скрипта:

- `CONTACT_EMAIL` - электронная почта для уведомлений Let's Encrypt. Если не задана, то используется регистрация без почты.
- `PUBLIC_IP` - публичный IPv4 для видеомоста, если автоопределение через таблицу маршрутизации не подходит.
- `MANAGER_IP` - интерфейсный IPv4 менеджера Swarm (обычно обнаруживается автоматически).
- `REF` - точная 40-символьная SHA ревизия GitHub, используемая CD.
- `NGINX_IMAGE` - тег подготовленного Nginx-образа из GHCR (передаётся CI). При ручном запуске образ собирается локально.

Скрипт создаёт секретный `.env`, каталоги `config/`, `upstream/`, `generated/` и `acme/`. Эти пути исключены из Git и не должны коммититься. Пароли Jitsi сохраняются между обновлениями, файлы `config` и ключи TLS сертификата не удаляются. Swarm runtime `/run` использует четыре tmpfs-backed Docker volume с флагом `exec`.

### Примечания

- По умолчанию комнаты анонимны, причём первый подключившийся участник (он же - создатель комнаты) сразу становится модератором.
- Передача голоса/видео идёт через Jitsi Videobridge по UDP/10000.
- Запись встреч, Jibri, внешний балансировщик и второй VPS пока не предусмотрены проектом. Задача была реализовать только базовую функциональность ВКС.
- Изменение файлов темы не требует перестройки React-интерфейса. Для применения JS-переопределений перезапускается только `web`.
- Для системы после установки резервная копия находится в `/root/mirea-stream-backups/` и содержит секретные ключи.
