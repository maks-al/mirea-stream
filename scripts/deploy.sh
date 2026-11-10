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
    # The plain Ubuntu 24.04 packages are the ones verified on the actual VPS.
    # No full-upgrade, extra Docker repository, or hidden APT output.
    export DEBIAN_FRONTEND=noninteractive
    apt update -y && apt install -y ca-certificates curl gnupg git openssl certbot python3 python3-yaml iproute2 docker.io docker-compose-v2 openssh-client openssh-server tar gzip
    systemctl enable --now docker certbot.timer
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

# Public HTTP-01 files must be readable by the unprivileged Nginx worker.
# The deployment-wide umask is 077 for secrets, so explicitly set directory modes.
# Do NOT chmod the whole project, config/, .env or /etc/letsencrypt.
prepare_acme_webroot() {
    install -d -m 755 "$ROOT/acme" "$ROOT/acme/.well-known" "$ROOT/acme/.well-known/acme-challenge"
}

sources() {
    require_root
    ensure_repo
    mkdir -p "$ROOT/upstream" "$ROOT/config" "$ROOT/generated"
    prepare_acme_webroot
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
    # All bind sources in pinned Jitsi Compose must exist BEFORE Swarm creates tasks.
    # Compose implicitly creates missing directories, whereas Swarm rejects the task.
    mkdir -p "$ROOT/config/web" "$ROOT/config/storage/web" "$ROOT/config/storage/transcripts" "$ROOT/config/prosody/config" "$ROOT/config/prosody/prosody-plugins-custom" "$ROOT/config/storage/prosody" "$ROOT/config/jicofo" "$ROOT/config/jvb" "$ROOT/config/tmp/web-load-test" \
        "$ROOT/config/web/custom-ca" "$ROOT/config/prosody/custom-ca" "$ROOT/config/jicofo/custom-ca" "$ROOT/config/jvb/custom-ca"
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
    # On the single-node Swarm, pre-pull the exact immutable release tag.
    # A registry/auth/network failure must stop the deploy before touching
    # the currently running service. This also primes the worker image cache.
    local desired_image="$(env_value NGINX_IMAGE)"
    if [[ "$desired_image" != mirea-stream-nginx:local ]]; then
        say "Pulling release image on the Swarm node: $desired_image"
        docker pull "$desired_image" || fail 'Cannot pull release image on VPS; inspect GHCR permissions and Docker network.'
    fi
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
    verify_nginx_release
}

verify_nginx_release() {
    require_root
    local expected_image="$(env_value NGINX_IMAGE)" state desired_image active_image replicas
    local expected_header actual_header i
    # Manual Compose/Swarm walkthroughs use a local image, not a GHCR release.
    [[ "$expected_image" == mirea-stream-nginx:local ]] && return 0
    expected_header="$(sed -nE 's/^[[:space:]]*add_header[[:space:]]+X-Mirea-Release[[:space:]]+"([^"]+)"[[:space:]]+always;.*/\1/p' "$ROOT/nginx/default.conf" | head -n 1)"
    [[ -n "$expected_header" ]] || fail 'No X-Mirea-Release value in source Nginx config.'
    say "Waiting for Swarm to activate image $expected_image (release $expected_header)"
    # Do not accept 1/1 alone. The *old* service may still be serving requests
    # while the new task is rejected and Swarm performs an automatic rollback.
    for i in $(seq 1 60); do
        state="$(docker service inspect "${STACK}_nginx" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)"
        case "$state" in
            rollback*|paused)
                docker service ps "${STACK}_nginx" --no-trunc || true
                fail "Nginx Swarm update did not converge (state: $state)."
                ;;
        esac
        desired_image="$(docker service inspect "${STACK}_nginx" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || true)"
        active_image="$(docker ps --filter status=running --filter "label=com.docker.swarm.service.name=${STACK}_nginx" --format '{{.Image}}' 2>/dev/null | head -n 1)"
        replicas="$(docker service ls --filter "name=${STACK}_nginx" --format '{{.Replicas}}' 2>/dev/null | head -n 1)"
        if [[ ( "$desired_image" == "$expected_image" || "$desired_image" == "$expected_image@sha256:"* ) &&
              ( "$active_image" == "$expected_image" || "$active_image" == "$expected_image@sha256:"* ) &&
              "$replicas" == 1/1 && ( "$state" == completed || -z "$state" ) ]]; then
            actual_header="$(curl -4fsSI --connect-timeout 3 --max-time 8 "https://$DOMAIN/" 2>/dev/null | tr -d '\r' | sed -nE 's/^[Xx]-[Mm]irea-[Rr]elease:[[:space:]]*(.*)$/\1/p' | head -n 1 || true)"
            if [[ "$actual_header" == "$expected_header" ]]; then
                say "Release verified: image $expected_image; HTTP header $actual_header"
                return 0
            fi
        fi
        sleep 3
    done
    docker service inspect "${STACK}_nginx" --format '{{json .UpdateStatus}}' || true
    docker service ps "${STACK}_nginx" --no-trunc || true
    fail "Nginx release not activated: expected image $expected_image and HTTP header $expected_header."
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
    # A running Swarm task (1/1) does not mean Jitsi's web server is ready.
    # During deploys, Nginx may briefly return 502 for the proxied JS routes.
    local http_ready=0 interface_js config_js
    say 'Waiting for Jitsi HTTP readiness'
    for i in $(seq 1 45); do
        if interface_js="$(curl -4fsS --connect-timeout 3 --max-time 8 "https://$DOMAIN/interface_config.js" 2>/dev/null)" &&
           [[ "$interface_js" == *"MIREA Stream"* ]] &&
           config_js="$(curl -4fsS --connect-timeout 3 --max-time 8 "https://$DOMAIN/config.js" 2>/dev/null)" &&
           [[ "$config_js" == *"config.dynamicBrandingUrl"* ]]; then
            http_ready=1
            break
        fi
        sleep 3
    done
    if (( ! http_ready )); then
        docker service ps "${STACK}_web" --no-trunc || true
        fail 'Jitsi HTTP readiness failed: interface/config JS unavailable or branding is missing.'
    fi
    curl -4fsSI --retry 8 --retry-delay 2 --max-time 15 "https://$DOMAIN/" >/dev/null || fail 'HTTPS smoke test failed.'
    curl -4fsSI --max-time 15 "https://$DOMAIN/config.js" >/dev/null || fail 'Missing Jitsi config.js.'
    curl -4fsSI --max-time 15 "https://$DOMAIN/brand/logo.svg" >/dev/null || fail 'Missing branded logo.'
    curl -4fsSI --max-time 15 "https://$DOMAIN/brand/background.webp" >/dev/null || fail 'Missing branded background.'
    curl -4fsSI --max-time 15 "https://$DOMAIN/images/welcome-background.png" >/dev/null || fail 'Missing welcome-page picture override.'
    curl -4fsSI --max-time 15 "https://$DOMAIN/brand/branding.json" >/dev/null || fail 'Missing brand JSON.'
    say 'PASS: 5/5 Swarm tasks, HTTPS, Jitsi config, branded assets'
    say 'Real audio/video and moderator behavior require a browser conference test.'
}

finalize_tls() {
    require_root
    prepare_acme_webroot
    # Verify the actual HTTP-01 route before changing Certbot's renewal mode.
    # 0644 is essential here because the deployment runs with umask 077.
    local probe="$ROOT/acme/.well-known/acme-challenge/mirea-probe-$$" response
    printf 'mirea-acme-ok\n' > "$probe"
    chmod 644 "$probe"
    if ! response="$(curl -4fsS --connect-timeout 5 --max-time 15 "http://$DOMAIN/.well-known/acme-challenge/${probe##*/}")"; then
        rm -f "$probe"
        fail 'ACME webroot is not reachable over HTTP; check Nginx and file permissions.'
    fi
    rm -f "$probe"
    [[ "$response" == mirea-acme-ok ]] || fail 'ACME webroot returned unexpected content.'
    say 'ACME HTTP-01 route verified'
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
