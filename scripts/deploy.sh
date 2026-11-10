#!/usr/bin/env bash
# MIREA Stream: single entry point for a clean Ubuntu 24.04 VPS and subsequent updates.
# Run as root. Do not delete /opt/mirea-stream, /etc/letsencrypt, or Docker volumes.
set -Eeuo pipefail
umask 077

ROOT=/opt/mirea-stream
DOMAIN=mirea.stream
REPO=https://github.com/maks-al/mirea-stream.git
JITSI_TAG=stable-11248-2
STACK=mirea
COMPOSE=(docker compose --project-directory "$ROOT" --env-file "$ROOT/.env" -f "$ROOT/upstream/docker-compose.yml" -f "$ROOT/docker-compose.override.yml")

say() { printf '[mirea] %s\n' "$*"; }
fail() { printf '[mirea] ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { [[ "$(id -u)" == 0 ]] || fail 'Run as root (sudo).'; }

ensure_repo() {
    if [[ ! -d "$ROOT/.git" ]]; then
        [[ ! -e "$ROOT" || ! "$(ls -A "$ROOT" 2>/dev/null)" ]] || fail "$ROOT is not an empty directory or a Git checkout"
        git clone --branch main --single-branch "$REPO" "$ROOT"
    fi
    [[ "$(git -C "$ROOT" remote get-url origin)" == "$REPO" ]] || fail "Unexpected Git origin at $ROOT"
    git -C "$ROOT" diff --quiet || fail 'Local tracked files modified; commit or stash before updating.'
    git -C "$ROOT" diff --cached --quiet || fail 'Git index contains local changes.'
    git -C "$ROOT" fetch --quiet origin main
    if [[ -n "${REF:-}" ]]; then
        [[ "$REF" =~ ^[a-f0-9]{40}$ ]] || fail 'REF must be a complete commit SHA.'
        git -C "$ROOT" cat-file -e "${REF}^{commit}" || fail 'Requested commit is missing.'
        git -C "$ROOT" merge-base --is-ancestor HEAD "$REF" || fail 'Ref is not a descendant; refusing rollback.'
        git -C "$ROOT" merge --ff-only "$REF"
    else
        git -C "$ROOT" merge --ff-only origin/main
    fi
    say "Source revision $(git -C "$ROOT" rev-parse --short HEAD)"
}

packages() {
    require_root
    # A supported, intentionally narrow coursework target; avoid modifying arbitrary VPS systems.
    source /etc/os-release
    [[ "$ID" == ubuntu && "$VERSION_ID" == 24.04* ]] || fail 'Designed for Ubuntu 24.04 LTS only.'
    if command -v docker >/dev/null && docker compose version >/dev/null 2>&1 && command -v certbot >/dev/null && python3 -c 'import yaml' >/dev/null 2>&1; then
        systemctl enable --now docker certbot.timer
        say 'Deployment prerequisites already present'
        return
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg git openssl certbot python3 python3-yaml iproute2
    if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' "${UBUNTU_CODENAME:-noble}" "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/docker.sources
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    systemctl enable --now docker
    systemctl enable --now certbot.timer
    docker info >/dev/null
    say "Docker: $(docker --version); Compose: $(docker compose version --short)"
}

set_env() {
    local name="$1" value="$2" path="$ROOT/.env"
    [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ && "$value" != *$'\n'* ]] || fail 'Invalid environment setting.'
    if grep -q "^${name}=" "$path"; then
        # Replace using Python to avoid sed delimiter and regular-expression escaping.
        ENV_KEY="$name" ENV_VALUE="$value" python3 - "$path" <<'PY'
import os, pathlib, sys
path=pathlib.Path(sys.argv[1]); key=os.environ['ENV_KEY']; value=os.environ['ENV_VALUE']
lines=path.read_text().splitlines()
lines=[key+'='+value if line.startswith(key+'=') else line for line in lines]
path.write_text('\n'.join(lines)+'\n')
PY
    else
        printf '%s=%s\n' "$name" "$value" >> "$path"
    fi
}

env_value() {
    local value
    value="$(grep -m1 "^$1=" "$ROOT/.env" || true)"
    printf '%s' "${value#*=}"
}

sources() {
    require_root
    ensure_repo
    mkdir -p "$ROOT/upstream" "$ROOT/config" "$ROOT/generated" "$ROOT/acme/.well-known/acme-challenge"
    chmod 700 "$ROOT/generated"
    if [[ ! -f "$ROOT/upstream/docker-compose.yml" || ! -f "$ROOT/upstream/env.example" ]]; then
        say "Downloading pinned Jitsi Docker sources $JITSI_TAG"
        local archive
        archive="$(mktemp)"
        trap 'rm -f "$archive"' RETURN
        curl -fLsS --retry 3 "https://github.com/jitsi/docker-jitsi-meet/archive/refs/tags/${JITSI_TAG}.tar.gz" -o "$archive"
        tar -xzf "$archive" --strip-components=1 -C "$ROOT/upstream"
        rm -f "$archive"
        trap - RETURN
    fi
    if [[ ! -f "$ROOT/.env" ]]; then
        cp "$ROOT/upstream/env.example" "$ROOT/.env"
        say 'Generated new .env'
    fi
    chmod 600 "$ROOT/.env"
    local ip image
    ip="${PUBLIC_IP:-$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)}"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Cannot detect IPv4; set PUBLIC_IP.'
    # Do not change media advertise address during an update unless explicitly requested.
    if [[ -z "$(env_value JVB_ADVERTISE_IPS)" || -n "${PUBLIC_IP:-}" ]]; then set_env JVB_ADVERTISE_IPS "$ip"; fi
    set_env CONFIG "$ROOT/config"
    set_env PUBLIC_URL "https://$DOMAIN"
    set_env DISABLE_HTTPS 1
    set_env ENABLE_HTTP_REDIRECT 0
    set_env ENABLE_LETSENCRYPT 0
    set_env JITSI_IMAGE_VERSION "$JITSI_TAG"
    set_env PROJECT_ROOT "$ROOT"
    set_env ENABLE_AUTH 0
    set_env ENABLE_GUESTS 0
    set_env ENABLE_AUTO_OWNER 1
    set_env DEFAULT_LANGUAGE ru
    if [[ -z "$(env_value JICOFO_AUTH_PASSWORD)" ]]; then set_env JICOFO_AUTH_PASSWORD "$(openssl rand -hex 24)"; fi
    if [[ -z "$(env_value JVB_AUTH_PASSWORD)" ]]; then set_env JVB_AUTH_PASSWORD "$(openssl rand -hex 24)"; fi
    image="${NGINX_IMAGE:-mirea-stream-nginx:local}"
    [[ "$image" =~ ^[a-zA-Z0-9./_:@-]+$ ]] || fail 'Invalid Nginx image name.'
    set_env NGINX_IMAGE "$image"
    mkdir -p "$ROOT/config/web" "$ROOT/config/storage/web" "$ROOT/config/storage/transcripts" "$ROOT/config/prosody/config" "$ROOT/config/prosody/prosody-plugins-custom" "$ROOT/config/storage/prosody" "$ROOT/config/jicofo" "$ROOT/config/jvb" "$ROOT/config/tmp/web-load-test"
    # Keep all Jitsi file mounts writable by the official rootless uid 1000.
    chown -R 1000:1000 "$ROOT/config"
    local changed=0
    for custom in custom-config.js custom-interface_config.js; do
        if ! cmp -s "$ROOT/branding/$custom" "$ROOT/config/web/$custom"; then
            install -m 644 -o 1000 -g 1000 "$ROOT/branding/$custom" "$ROOT/config/web/$custom"
            changed=1
        fi
    done
    printf '%s\n' "$changed" > "$ROOT/generated/branding-changed"
    chmod 600 "$ROOT/generated/branding-changed"
    say "Prepared configuration and branding (JVB advertise $(env_value JVB_ADVERTISE_IPS))"
}

certificate() {
    require_root
    if [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" && -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
        say 'TLS certificate already exists; preserving it'
        return
    fi
    # Initial standalone challenge requires free port 80; run before Compose/Swarm.
    if ss -lnt '( sport = :80 )' | grep -q ':80'; then fail 'Port 80 is busy; cannot issue first TLS certificate.'; fi
    local mail=()
    if [[ -n "${CONTACT_EMAIL:-}" ]]; then
        mail=(--email "$CONTACT_EMAIL")
    else
        mail=(--register-unsafely-without-email)
    fi
    certbot certonly --standalone --preferred-challenges http --agree-tos --non-interactive "${mail[@]}" -d "$DOMAIN"
}

render() {
    [[ -f "$ROOT/.env" ]] || fail 'Missing .env; run sources first.'
    "${COMPOSE[@]}" config --format json > "$ROOT/generated/compose-resolved.json"
    python3 "$ROOT/scripts/render-swarm.py" "$ROOT/generated/compose-resolved.json" "$ROOT/generated/stack.swarm.yml"
    docker stack config --compose-file "$ROOT/generated/stack.swarm.yml" >/dev/null
    chmod 600 "$ROOT/generated/compose-resolved.json" "$ROOT/generated/stack.swarm.yml"
}

build_local_nginx() {
    if [[ "$(env_value NGINX_IMAGE)" == mirea-stream-nginx:local ]]; then
        docker build -f "$ROOT/nginx/Dockerfile" -t mirea-stream-nginx:local "$ROOT"
    fi
}

compose_demo() {
    require_root
    [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] || fail 'Certificate missing.'
    [[ "$(env_value NGINX_IMAGE)" == mirea-stream-nginx:local ]] || fail 'Manual Compose stage requires local Nginx image.'
    "${COMPOSE[@]}" config -q
    "${COMPOSE[@]}" up -d --build
    "${COMPOSE[@]}" ps
}

swarm_deploy() {
    require_root
    [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] || fail 'Certificate missing.'
    bash "$ROOT/scripts/setup-swarm-volumes.sh"
    render
    build_local_nginx
    if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" == inactive ]]; then
        local ip="$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
        [[ -n "$ip" ]] || fail 'Cannot determine manager address.'
        docker swarm init --advertise-addr "${MANAGER_IP:-$ip}"
    fi
    [[ "$(docker info --format '{{.Swarm.ControlAvailable}}')" == true ]] || fail 'Must deploy on a Swarm manager.'
    # Tear down only this project's Compose services. Do not prune volumes.
    if [[ -n "$("${COMPOSE[@]}" ps -q)" ]]; then "${COMPOSE[@]}" down; fi
    local already=0
    docker service inspect "${STACK}_web" >/dev/null 2>&1 && already=1
    local resolve=changed
    [[ "$(env_value NGINX_IMAGE)" == mirea-stream-nginx:local ]] && resolve=never
    docker stack deploy --resolve-image "$resolve" --with-registry-auth --compose-file "$ROOT/generated/stack.swarm.yml" "$STACK"
    # A stable local image tag is not recognized as changed by Swarm; refresh
    # that service explicitly. A mounted brand JS change also needs web restart.
    if (( already )); then
        if [[ "$(env_value NGINX_IMAGE)" == mirea-stream-nginx:local ]]; then docker service update --force "${STACK}_nginx"; fi
        if [[ "$(cat "$ROOT/generated/branding-changed")" == 1 ]]; then docker service update --force "${STACK}_web"; fi
    fi
}

check() {
    require_root
    local found=0 i output
    for i in $(seq 1 60); do
        output="$(docker stack services "$STACK" --format '{{.Name}} {{.Replicas}}' 2>/dev/null || true)"
        if [[ "$(printf '%s\n' "$output" | grep -cE '^mirea_(web|prosody|jicofo|jvb|nginx) 1/1$' || true)" == 5 ]]; then found=1; break; fi
        sleep 3
    done
    docker node ls
    docker stack services "$STACK"
    if (( ! found )); then docker stack ps "$STACK" --no-trunc; fail 'Not all five services reached 1/1.'; fi
    curl -4fsSI --retry 8 --retry-delay 2 --max-time 15 "https://$DOMAIN/" >/dev/null || fail 'HTTPS smoke test failed.'
    curl -4fsSI --max-time 15 "https://$DOMAIN/config.js" >/dev/null || fail 'Missing Jitsi config.js.'
    curl -4fsSI --max-time 15 "https://$DOMAIN/brand/logo.svg" >/dev/null || fail 'Missing branded logo.'
    curl -4fsSI --max-time 15 "https://$DOMAIN/brand/background.webp" >/dev/null || fail 'Missing branded background.'
    curl -4fsSI --max-time 15 "https://$DOMAIN/images/welcome-background.png" >/dev/null || fail 'Missing welcome-page picture override.'
    curl -4fsSI --max-time 15 "https://$DOMAIN/brand/branding.json" >/dev/null || fail 'Missing brand JSON.'
    curl -4fsS --max-time 15 "https://$DOMAIN/interface_config.js" | grep -F 'MIREA Stream' >/dev/null || fail 'Interface branding is not active.'
    curl -4fsS --max-time 15 "https://$DOMAIN/config.js" | grep -F 'brandingDataUrl' >/dev/null || fail 'Jitsi branding JSON URL is missing.'
    say 'PASS: 5/5 Swarm tasks, HTTPS, Jitsi config, branded assets'
    say 'Real audio/video and moderator behavior require a browser conference test.'
}

finalize_tls() {
    require_root
    install -D -m 755 "$ROOT/scripts/renew-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/mirea-nginx-reload.sh
    systemctl enable --now certbot.timer
    if ! grep -Eq '^authenticator *= *webroot' "/etc/letsencrypt/renewal/$DOMAIN.conf"; then
        certbot reconfigure --cert-name "$DOMAIN" --webroot -w "$ROOT/acme"
    fi
    certbot renew --cert-name "$DOMAIN" --dry-run
    say 'TLS renewal verified'
}

main() {
    require_root
    case "${1:-}" in
        packages) packages ;;
        sources) sources ;;
        certificate) certificate ;;
        compose) compose_demo ;;
        swarm) swarm_deploy ;;
        tls) finalize_tls ;;
        check) check ;;
        install)
            packages
            sources
            certificate
            swarm_deploy
            check
            finalize_tls
            bash "$ROOT/scripts/backup.sh"
            ;;
        auto)
            if [[ -f "$ROOT/.env" ]]; then
                packages
                bash "$ROOT/scripts/backup.sh"
                sources
                swarm_deploy
                check
            else
                packages
                sources
                certificate
                swarm_deploy
                check
                finalize_tls
                bash "$ROOT/scripts/backup.sh"
            fi
            ;;
        update)
            [[ -f "$ROOT/.env" ]] || fail 'Not installed; use install instead.'
            packages
            bash "$ROOT/scripts/backup.sh"
            sources
            swarm_deploy
            check
            ;;
        *)
            echo 'Usage: bash scripts/deploy.sh {install|update|auto|packages|sources|certificate|compose|swarm|tls|check}' >&2
            exit 2
            ;;
    esac
}
main "$@"
