#!/usr/bin/env bash
# rw-ins — single-file RemnaNode maintenance CLI, preview 0.2.0
# Ubuntu/Debian, bash 4.4+, systemd. Does not execute third-party Bash installers.
set -Eeuo pipefail
umask 077

VERSION='0.3.0-preview'
SELF='/usr/local/bin/rw-ins'
SELF_URL='https://raw.githubusercontent.com/KinG123124/remnanode-installer/refs/heads/main/install.sh'
STATE='/etc/rw-ins'
NODE_DIR='/opt/remnanode'
NODE_IMAGE='remnawave/node:2.8.0'  # intentionally pinned; never update implicitly
SITE='/var/www/rw-ins-site'
WEBROOT='/var/www/rw-ins-acme'
DOMAIN_FILE="$STATE/domain"
CONF='/etc/nginx/sites-available/rw-ins-site.conf'
CONF_LINK='/etc/nginx/sites-enabled/rw-ins-site.conf'
EDGE_FILE='/etc/nginx/conf.d/rw-ins-edge.disabled' # staging is not loaded by nginx
EDGE_ACTIVE='/etc/nginx/rw-ins-edge.conf'
CERT_DEST='/etc/xray-certs/hy2'
HOOK='/etc/letsencrypt/renewal-hooks/deploy/rw-ins-sync'
FW_CONF="$STATE/api-firewall.conf"
FW_UNIT='/etc/systemd/system/rw-ins-api-firewall.service'
FW_C4='RWINSAPI4'
FW_C6='RWINSAPI6'
FW_TAG='rw-ins-node-api'
BACKUPS='/var/backups/rw-ins'
# Existing (legacy) selfsteal, installed by the former third-party installer.
LEGACY_DIR='/opt/nginx-selfsteal'
LEGACY_MAIN="$LEGACY_DIR/nginx.conf"
LEGACY_SITE="$LEGACY_DIR/conf.d/selfsteal.conf"
LEGACY_TLS="$LEGACY_DIR/conf.d/rwins-edge-https.conf"
LEGACY_STREAM_DIR="$LEGACY_DIR/conf.d/rwins-stream"
LEGACY_STREAM="$LEGACY_STREAM_DIR/edge.conf"
LEGACY_STATE="$STATE/legacy-edge.env"
LEGACY_MARK_BEGIN='# BEGIN RWINS LEGACY SNI EDGE'
LEGACY_MARK_END='# END RWINS LEGACY SNI EDGE'

info(){ printf '\033[34m[i]\033[0m %s\n' "$*"; }
ok(){ printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Не найдена команда $1"; }
ask(){ local v; printf '%s' "$1" >/dev/tty; IFS= read -r v </dev/tty || return 1; REPLY="$v"; }
secret_ask(){ local v; printf '%s' "$1" >/dev/tty; IFS= read -rs v </dev/tty || return 1; printf '\n' >/dev/tty; REPLY="$v"; }
yesno(){ ask "$1 [y/N]: "; [[ "${REPLY,,}" == 'y' || "${REPLY,,}" == 'yes' || "${REPLY,,}" == 'д' ]]; }
valid_domain(){ [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ && ${#1} -le 253 ]]; }
valid_ipv4(){ local ip="$1" i; [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; local -a nums; IFS=. read -ra nums <<< "$ip"; for i in "${nums[@]}"; do [[ $i =~ ^[0-9]{1,3}$ ]] && (( 10#$i <= 255 )) || return 1; done; [[ $ip != 0.0.0.0 && $ip != 255.255.255.255 ]]; }
valid_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
root_only(){ (( EUID == 0 )) || die 'Запусти с sudo/root'; [[ -r /dev/tty ]] || [[ "${1:-}" == 'noninteractive' ]] || die 'Для меню нужен интерактивный терминал'; }
base_os(){ local ID VERSION VERSION_CODENAME PRETTY_NAME; [[ -r /etc/os-release ]] || die 'Нужен Ubuntu/Debian'; . /etc/os-release; [[ $ID == ubuntu || $ID == debian ]] || die 'Поддерживаются Ubuntu/Debian'; }
init(){ root_only noninteractive; base_os; mkdir -p "$STATE" "$BACKUPS"; chmod 700 "$STATE" "$BACKUPS"; }
backup(){ local p="$1" sub; [[ -e "$p" || -L "$p" ]] || return 0; sub="$BACKUPS/$(date +%Y%m%d-%H%M%S)-$$"; mkdir -p "$sub"; cp -a "$p" "$sub/"; info "Резервная копия: $sub/$(basename "$p")"; }
apt_install(){ export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y "$@"; }

# bash -c "$(curl ...)" has no source pathname, but Bash exposes its command text.
# This saves exactly the code that is currently running, not a newer upstream version.
install_self(){
  init
  local candidate='' tmp
  tmp="$(mktemp "$STATE/self.XXXXXXXX")"
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    candidate="${BASH_SOURCE[0]}"
    cp "$candidate" "$tmp"
  elif [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
    printf '%s\n' "$BASH_EXECUTION_STRING" > "$tmp"
  else
    rm -f "$tmp"
    die 'Не удалось определить исходный код. Используй: sudo bash /path/to/install.sh'
  fi
  if ! bash -n "$tmp"; then rm -f "$tmp"; die 'Ошибка синтаксиса исходного скрипта'; fi
  if [[ -f "$SELF" ]] && cmp -s "$tmp" "$SELF"; then rm -f "$tmp"; return; fi
  [[ -e "$SELF" ]] && backup "$SELF"
  install -m 0755 "$tmp" "$SELF"
  rm -f "$tmp"
  ok "Команда rw-ins установлена: $SELF"
}

ensure_docker(){
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    systemctl is-active --quiet docker || systemctl start docker
    ok 'Docker + Compose уже установлены'; return
  fi
  info 'Устанавливаю Docker и Compose. Существующие контейнеры не удаляются.'
  apt_install ca-certificates curl gnupg
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    apt_install docker.io docker-compose-v2
  elif apt-cache show docker-compose-plugin >/dev/null 2>&1 && apt-cache show docker.io >/dev/null 2>&1; then
    apt_install docker.io docker-compose-plugin
  else
    # Official Docker apt repository; apt verifies its signed repository metadata.
    local ID VERSION VERSION_CODENAME PRETTY_NAME
    . /etc/os-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    local arch codename
    arch="$(dpkg --print-architecture)"; codename="${VERSION_CODENAME:-}"
    [[ -n "$codename" ]] || die 'Не определён codename ОС'
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' "$arch" "$ID" "$codename" > /etc/apt/sources.list.d/docker-ce.list
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker
  docker compose version >/dev/null 2>&1 || die 'Docker Compose недоступен'
}

node_exists(){
  [[ -f "$NODE_DIR/docker-compose.yml" || -f "$NODE_DIR/compose.yaml" ]] && return 0
  command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq remnanode
}
install_node(){
  ensure_docker
  if node_exists; then ok 'RemnaNode уже обнаружена — не перезаписываю Compose и .env'; return; fi
  secret_ask 'SECRET_KEY из панели Remnawave: '
  local secret="$REPLY" port
  [[ -n "$secret" && "$secret" =~ ^[A-Za-z0-9._+/=-]+$ ]] || die 'Некорректный SECRET_KEY: нужны символы base64/URL-safe, без пробелов и переносов'
  ask 'NODE_PORT [2222]: '; port="${REPLY:-2222}"
  valid_port "$port" || die 'Некорректный порт'
  mkdir -p "$NODE_DIR" "$CERT_DEST"
  chmod 700 "$NODE_DIR"
  printf 'SECRET_KEY=%s\n' "$secret" > "$NODE_DIR/.env"
  chmod 600 "$NODE_DIR/.env"
  unset secret REPLY
  cat > "$NODE_DIR/docker-compose.yml" <<YAML
services:
  remnanode:
    image: $NODE_IMAGE
    container_name: remnanode
    hostname: remnanode
    restart: unless-stopped
    network_mode: host
    env_file:
      - .env
    environment:
      NODE_PORT: "$port"
    volumes:
      - /dev/shm:/dev/shm
      - $CERT_DEST:$CERT_DEST:ro
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
YAML
  chmod 600 "$NODE_DIR/docker-compose.yml"
  (cd "$NODE_DIR" && docker compose config -q)
  info 'Рекомендуется закрыть NODE_PORT до запуска ноды.'
  if yesno 'Ограничить NODE_PORT доступом только с публичного IPv4 панели?'; then
    local panel_ip
    ask 'Публичный IPv4 панели: '; panel_ip="$REPLY"
    valid_ipv4 "$panel_ip" || die 'Некорректный IP панели — нода пока не запущена'
    command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1 || apt_install iptables
    fw_apply "$panel_ip" "$port"
    fw_persist
    ok "API порта $port ограничен IP панели ещё до запуска ноды"
  else
    warn "NODE_PORT $port останется публичным до выполнения пункта защиты API в меню."
  fi
  (cd "$NODE_DIR" && docker compose up -d)
  ok "RemnaNode ($NODE_IMAGE) запущена на NODE_PORT $port"
  warn 'Назначь Config Profile в панели и проверь соединение с нодой.'
}

node_port(){
  if [[ -f "$FW_CONF" ]]; then . "$FW_CONF"; printf '%s' "$PORT"; return; fi
  # Detect when possible; avoid reading a user's SECRET_KEY from docker compose.
  if command -v docker >/dev/null 2>&1; then
    local p
    p="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' remnanode 2>/dev/null | sed -n 's/^NODE_PORT=//p' | head -1 || true)"
    if valid_port "$p"; then printf '%s' "$p"; return; fi
  fi
  printf '2222'
}

ensure_nginx(){
  command -v nginx >/dev/null 2>&1 || apt_install nginx libnginx-mod-stream
  if [[ ! -f /usr/lib/nginx/modules/ngx_stream_module.so ]] && ! nginx -V 2>&1 | grep -q -- '--with-stream=static'; then
    # On Debian/Ubuntu the dynamic stream module is packaged separately.
    apt_install libnginx-mod-stream
  fi
  if ! nginx -V 2>&1 | grep -Eq '(--with-stream_ssl_preread_module|--with-stream_ssl_preread_module=dynamic)'; then
    warn 'Модуль ssl_preread не подтверждён; перед активацией проверь nginx -t.'
  fi
}

write_webroot(){
  local d="$1"
  mkdir -p "$WEBROOT/.well-known/acme-challenge" "$SITE" /etc/nginx/sites-available /etc/nginx/sites-enabled
  if [[ -e "$CONF" ]]; then backup "$CONF"; fi
  cat > "$CONF" <<NG
# Generated by rw-ins $VERSION; only for $d.
server {
  listen 80;
  listen [::]:80;
  server_name $d;
  location ^~ /.well-known/acme-challenge/ { root $WEBROOT; default_type text/plain; }
  location / { return 301 https://\$host\$request_uri; }
}
NG
  ln -sfn "$CONF" "$CONF_LINK"
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

ensure_certbot(){ command -v certbot >/dev/null 2>&1 || apt_install certbot ca-certificates; }
issue_cert(){
  local d="$1" email="$2" lineage="/etc/letsencrypt/live/$d"
  ensure_certbot
  if [[ -s "$lineage/fullchain.pem" && -s "$lineage/privkey.pem" ]]; then
    ok "Уже есть сертификат для $d"
    local renewal="/etc/letsencrypt/renewal/$d.conf"
    if [[ -f "$renewal" ]] && grep -Eq '^authenticator\s*=\s*standalone' "$renewal"; then
      warn "Старый сертификат $d использует standalone. Его автопродление может конфликтовать с Nginx на 80 порту."
      if yesno 'Попробовать certbot reconfigure (webroot), проверив тестовое продление?'; then
        certbot reconfigure --cert-name "$d" --authenticator webroot --webroot-path "$WEBROOT" --non-interactive || warn 'Не удалось переписать renewal. Проверь certbot renew --dry-run.'
      fi
    fi
    return
  fi
  info "Получаю сертификат для $d через HTTP-01 webroot. DNS домена должен указывать на эту ноду, TCP/80 открыт."
  certbot certonly --webroot -w "$WEBROOT" --non-interactive --agree-tos --email "$email" --key-type ecdsa -d "$d"
  [[ -r "$lineage/fullchain.pem" && -r "$lineage/privkey.pem" ]] || die 'Certbot не выпустил сертификат'
}

write_hook(){
  mkdir -p "$(dirname "$HOOK")"
  cat > "$HOOK" <<'HOOK_BODY'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ -r /etc/rw-ins/domain ]] || exit 0
domain="$(cat /etc/rw-ins/domain)"
src="/etc/letsencrypt/live/$domain"
[[ -r "$src/fullchain.pem" && -r "$src/privkey.pem" ]] || exit 0
[[ -z "${RENEWED_LINEAGE:-}" || "${RENEWED_LINEAGE%/}" == "$src" ]] || exit 0
out=/etc/xray-certs/hy2
mkdir -p "$out"
changed=0
if ! cmp -s "$src/fullchain.pem" "$out/fullchain.pem"; then
  install -m 0644 "$src/fullchain.pem" "$out/fullchain.pem"; changed=1
fi
if ! cmp -s "$src/privkey.pem" "$out/privkey.pem"; then
  install -m 0600 "$src/privkey.pem" "$out/privkey.pem"; changed=1
fi
if (( changed )); then
  systemctl is-active --quiet nginx && systemctl reload nginx || true
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -Fxq remnanode; then
    docker restart remnanode >/dev/null
  fi
fi
HOOK_BODY
  chmod 700 "$HOOK"
  "$HOOK"
  systemctl enable --now certbot.timer 2>/dev/null || warn 'Не удалось включить certbot.timer'
}

selfsteal(){
  if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -Fxq nginx-selfsteal; then
    die 'Есть существующий контейнер nginx-selfsteal. Автоматически его не заменяю: возможен конфликт сокета. На старых нодах используйте только пункт firewall.'
  fi
  ask 'Домен этой ноды (например de.veloragrid.site): '; local d="${REPLY,,}" email
  valid_domain "$d" || die 'Некорректный домен'
  ask 'Email для Let’s Encrypt: '; email="$REPLY"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Некорректный email'
  ensure_nginx
  [[ ! -e "$CONF" ]] || { yesno "Пересоздать управляемый конфиг $CONF?" || return; }
  write_webroot "$d"
  issue_cert "$d" "$email"
  backup "$CONF"
  cat >> "$CONF" <<NG
server {
  listen 127.0.0.1:9443 ssl http2;
  listen unix:/dev/shm/nginx.sock ssl proxy_protocol http2;
  server_name $d;
  ssl_certificate /etc/letsencrypt/live/$d/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$d/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  server_tokens off;
  root $SITE;
  index index.html;
  location / { try_files \$uri \$uri/ /index.html; }
}
NG
  if [[ ! -f "$SITE/index.html" ]]; then
    cat > "$SITE/index.html" <<'HTML'
<!doctype html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title><style>body{font-family:system-ui;margin:10vh auto;max-width:720px;padding:0 24px;color:#283344}h1{font-weight:600}</style></head><body><h1>Welcome</h1><p>Service is online.</p></body></html>
HTML
    chmod 644 "$SITE/index.html"
  fi
  if ! nginx -t; then
    die 'Конфигурация Nginx не прошла проверку; резервная копия в /var/backups/rw-ins. Восстанови вручную перед reload.'
  fi
  systemctl reload nginx
  printf '%s\n' "$d" > "$DOMAIN_FILE"; chmod 600 "$DOMAIN_FILE"
  write_hook
  [[ -S /dev/shm/nginx.sock ]] || die 'Unix-сокет nginx не найден после перезагрузки'
  ok "Selfsteal установлен: $d. Для REALITY target=/dev/shm/nginx.sock, xver=1."
  warn 'Это не включает SNI edge. По умолчанию публичный 443 остаётся у Xray.'
}

hy2_certs(){
  local d email
  if [[ -s "$DOMAIN_FILE" ]]; then
    d="$(cat "$DOMAIN_FILE")"
    if [[ -s "/etc/letsencrypt/live/$d/fullchain.pem" ]]; then
      write_hook
      ok "Сертификаты синхронизированы из $d в $CERT_DEST."
      return
    fi
  fi
  if [[ -s "$CERT_DEST/fullchain.pem" && -s "$CERT_DEST/privkey.pem" ]]; then
    ok "Сертификаты уже есть в $CERT_DEST. Не перезаписываю действующие файлы."
    warn 'Убедись, что их продление настроено вне rw-ins.'
    return
  fi
  warn 'Для выпуска HY2/XHTTP нужен домен, указывающий на этот сервер, и открытый TCP/80.'
  if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -Fxq nginx-selfsteal; then
    warn 'Есть Docker selfsteal. Он не будет изменён; проверяй конфликты порта 80.'
  fi
  ask 'Домен для сертификата HY2/XHTTP: '; d="${REPLY,,}"
  valid_domain "$d" || die 'Некорректный домен'
  ask 'Email для Let’s Encrypt: '; email="$REPLY"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Некорректный email'
  ensure_nginx
  if [[ -e "$CONF" ]]; then
    warn "На этом сервере уже есть конфиг $CONF."
    yesno 'Обновить управляемую HTTP-конфигурацию для выпуска сертификата?' || return
  fi
  write_webroot "$d"
  issue_cert "$d" "$email"
  printf '%s\n' "$d" > "$DOMAIN_FILE"; chmod 600 "$DOMAIN_FILE"
  write_hook
  ok "TLS-файлы Hysteria2/XHTTP: $CERT_DEST/fullchain.pem и privkey.pem"
  warn 'Если существующий selfsteal управляет TLS отдельно, проверь его сертификат перед изменением домена.'
}

host_edge_prepare(){
  need nginx
  [[ -s "$DOMAIN_FILE" ]] || die 'Сначала настрой selfsteal'
  [[ -S /dev/shm/nginx.sock ]] || die 'Unix-сокет selfsteal отсутствует'
  [[ ! -f "$EDGE_ACTIVE" ]] || die 'SNI edge уже активен'
  local d; d="$(cat "$DOMAIN_FILE")"
  mkdir -p /etc/nginx
  cat > "$EDGE_FILE" <<NG
# Created by rw-ins. Deliberately staged; not active until edge-activate.
stream {
  map \$ssl_preread_server_name \$rwins_backend {
    $d 127.0.0.1:1443;
    default 127.0.0.1:9443;
  }
  server {
    listen 0.0.0.0:443;
    listen [::]:443 ipv6only=on;
    ssl_preread on;
    preread_buffer_size 64k;
    preread_timeout 15s;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;
    proxy_pass \$rwins_backend;
  }
}
NG
  chmod 644 "$EDGE_FILE"
  # Validate syntax with temp main config; stream module is loaded by nginx.conf.
  local tmp; tmp="$(mktemp /etc/nginx/rwins-test.XXXXXX)"
  printf 'include /etc/nginx/nginx.conf;\ninclude %s;\n' "$EDGE_FILE" > "$tmp"
  nginx -p /etc/nginx -c "$tmp" -t
  rm -f "$tmp"
  ok "Подготовлен: $EDGE_FILE"
  warn 'Для тестовой ноды REALITY должен слушать 127.0.0.1:1443, а не 0.0.0.0:443.'
  warn 'Если используешь один Config Profile на всех нодах — сделай временный тестовый профиль. Не переключай всех одновременно.'
}
host_edge_activate(){
  [[ -s "$EDGE_FILE" ]] || die 'Сначала выбери Подготовить SNI edge'
  [[ ! -e "$EDGE_ACTIVE" ]] || die 'SNI edge уже активен'
  local x;
  x="$(ss -H -lnt '( sport = :1443 )' | awk '{print $4}')"
  grep -Fxq '127.0.0.1:1443' <<< "$x" || die 'Нет Xray на 127.0.0.1:1443. Сначала переключи тестовый профиль.'
  if ss -H -lnt '( sport = :443 )' | grep -q .; then
    ss -H -lntp '( sport = :443 )'
    die '443/TCP занят. Сначала освободи порт от старого Xray.'
  fi
  yesno 'Активировать Nginx на 443/TCP?' || return
  if grep -Fq 'include /etc/nginx/rw-ins-edge.conf;' /etc/nginx/nginx.conf; then
    :
  else
    backup /etc/nginx/nginx.conf
    printf '\n# rw-ins SNI edge, top-level stream context\ninclude /etc/nginx/rw-ins-edge.conf;\n' >> /etc/nginx/nginx.conf
  fi
  cp "$EDGE_FILE" "$EDGE_ACTIVE"
  if ! nginx -t || ! systemctl reload nginx; then
    rm -f "$EDGE_ACTIVE"
    nginx -t && systemctl reload nginx || true
    die 'Не удалось включить SNI edge; конфиг отключён. Проверь состояние порта 443.'
  fi
  ok 'SNI edge включён. Свой SNI → REALITY localhost:1443; чужие SNI → обычный HTTPS localhost:9443.'
  warn 'Это не гарантирует защиту от IP-блокировок. Проверь параллельные подключения и fallback перед развёртыванием на других нодах.'
}
host_edge_disable(){
  [[ -e "$EDGE_ACTIVE" ]] || { warn 'SNI edge не включён'; return; }
  warn 'Xray по-прежнему будет слушать только localhost:1443, и внешний VPN пропадёт после отключения Nginx edge.'
  yesno 'Отключить SNI edge? Используй консоль провайдера или подготовь возврат Xray в профиль.' || return
  backup "$EDGE_ACTIVE"
  rm -f "$EDGE_ACTIVE"
  nginx -t && systemctl reload nginx || die 'Не удалось перезагрузить Nginx'
  ok 'SNI edge отключён. Верни публичный Xray listener только после проверки.'
}

# ---------------- Existing Docker-based selfsteal migration ----------------
# Does NOT replace the container, its mount layout, ACME, HTML, or certificate files.
legacy_container_exists(){
  command -v docker >/dev/null 2>&1 && \
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq nginx-selfsteal
}
legacy_container_running(){
  command -v docker >/dev/null 2>&1 && \
    docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq nginx-selfsteal
}
legacy_require(){
  legacy_container_running || die 'nginx-selfsteal не запущен; старую установку менять нельзя'
  [[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' nginx-selfsteal 2>/dev/null)" == host ]] || die 'Ожидался Docker network_mode=host'
  local m
  m="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/nginx/nginx.conf"}}{{.Source}}{{end}}{{end}}' nginx-selfsteal)"
  [[ "$m" == "$LEGACY_MAIN" ]] || die "Неожиданный mount nginx.conf ($m); не меняю конфиг"
  m="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/nginx/conf.d"}}{{.Source}}{{end}}{{end}}' nginx-selfsteal)"
  [[ "$m" == "$LEGACY_DIR/conf.d" ]] || die "Неожиданный mount conf.d ($m); не меняю конфиг"
  [[ -f "$LEGACY_MAIN" && -f "$LEGACY_SITE" ]] || die 'Не найдены конфиги прежнего selfsteal'
  grep -Fq 'unix:/dev/shm/nginx.sock' "$LEGACY_SITE" || die 'Не подтверждён старый REALITY fallback Unix-сокет'
  grep -Eq 'proxy_protocol' "$LEGACY_SITE" || die 'Не подтверждён PROXY protocol в старом selfsteal'
  docker exec nginx-selfsteal nginx -V 2>&1 | grep -q -- '--with-stream_ssl_preread_module' || die 'nginx-selfsteal не поддерживает ssl_preread'
  docker exec nginx-selfsteal nginx -t || die 'Существующая конфигурация Nginx невалидна; нельзя обновлять'
  [[ -S /dev/shm/nginx.sock ]] || die 'Unix-сокет Nginx отсутствует'
  [[ -s "$LEGACY_DIR/ssl/fullchain.crt" && -s "$LEGACY_DIR/ssl/private.key" ]] || die 'Нет TLS-сертификатов старого selfsteal'
}
legacy_domain(){
  local d
  d="$(awk '/^[[:space:]]*server_name[[:space:]]+/ {x=$2; sub(/;.*/, "", x); print tolower(x); exit}' "$LEGACY_SITE")"
  valid_domain "$d" || die "Не удалось распознать домен selfsteal ($d)"
  printf '%s' "$d"
}
legacy_mode(){
  [[ -f "$LEGACY_STREAM" ]] || { echo 'off'; return; }
  if grep -Fq 'listen 127.0.0.1:9444;' "$LEGACY_STREAM"; then echo 'test'
  elif grep -Fq 'listen 0.0.0.0:443;' "$LEGACY_STREAM"; then echo 'active'
  else echo 'unknown'; fi
}
legacy_port_busy(){
  local p="$1"
  ss -H -lnt "( sport = :$p )" 2>/dev/null | grep -q .
}
legacy_record_state(){
  local domain="$1" mode="$2" backup_dir="$3"
  # Only validated domain and controlled local path are written to this sourceable file.
  printf 'DOMAIN=%s\nMODE=%s\nBACKUP=%s\n' "$domain" "$mode" "$backup_dir" > "$LEGACY_STATE"
  chmod 600 "$LEGACY_STATE"
}
legacy_restore_before_reload(){
  local saved_main="$1"
  cp -a "$saved_main" "$LEGACY_MAIN"
  rm -f "$LEGACY_TLS" "$LEGACY_STREAM" "$LEGACY_STATE"
  docker exec nginx-selfsteal nginx -t >/dev/null 2>&1 || warn 'Даже исходный Nginx не прошёл nginx -t — проверь конфиг вручную'
}
legacy_prepare(){
  legacy_require
  local d mode snapshot
  d="$(legacy_domain)"
  mode="$(legacy_mode)"
  if [[ "$mode" == test || "$mode" == active ]]; then
    ok "SNI Edge уже подготовлен: $mode, домен $d"
    legacy_test
    return
  fi
  [[ "$mode" == off ]] || die "Неизвестное состояние SNI Edge: $mode"
  [[ ! -e "$LEGACY_TLS" && ! -e "$LEGACY_STREAM" ]] || die 'Есть файлы rw-ins с неизвестным содержимым. Не перезаписываю'
  if grep -Eq '^[[:space:]]*stream[[:space:]]*\{' "$LEGACY_MAIN"; then
    die 'В основном nginx.conf уже есть stream. Во избежание конфликта нужна ручная проверка'
  fi
  if grep -Fq "$LEGACY_MARK_BEGIN" "$LEGACY_MAIN"; then
    die 'Маркер rw-ins в nginx.conf уже присутствует; автоматическая повторная установка запрещена'
  fi
  grep -Fq 'include /etc/nginx/conf.d/*.conf;' "$LEGACY_MAIN" || die 'Не найден типовой http include; конфиг нестандартный'
  for p in 9443 9444; do
    legacy_port_busy "$p" && die "TCP/$p уже занят, тестовые порты недоступны"
  done
  printf '\nНайден прежний selfsteal, домен: %s\n' "$d"
  info 'Добавлю только HTTP listener 127.0.0.1:9443 и stream listener 127.0.0.1:9444.'
  info 'Публичный Xray :443, API :2222, HY2 :443/UDP и XHTTP :8443 не меняются.'
  yesno 'Создать тестовый SNI Edge и перечитать Nginx?' || return
  snapshot="$BACKUPS/legacy-edge-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$snapshot" "$LEGACY_STREAM_DIR"
  cp -a "$LEGACY_MAIN" "$snapshot/nginx.conf"
  cp -a "$LEGACY_SITE" "$snapshot/selfsteal.conf"
  cat > "$LEGACY_TLS" <<NG
# Managed by rw-ins; loopback-only HTTPS default for foreign/missing SNI.
server {
    listen 127.0.0.1:9443 ssl;
    server_name $d;
    ssl_certificate /etc/nginx/ssl/fullchain.crt;
    ssl_certificate_key /etc/nginx/ssl/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/html;
    index index.html index.htm;
    location / { try_files \$uri \$uri/ /index.html; }
}
NG
  cat > "$LEGACY_STREAM" <<NG
# RWINS LEGACY EDGE: TEST MODE; only loopback, production :443 not touched.
log_format rwins_edge '\$remote_addr [\$time_local] sni="\$ssl_preread_server_name" upstream="\$upstream_addr" status=\$status';
access_log /var/log/nginx/rwins-edge.log rwins_edge;
map \$ssl_preread_server_name \$rwins_backend {
    $d 127.0.0.1:443;
    default 127.0.0.1:9443;
}
server {
    listen 127.0.0.1:9444;
    ssl_preread on;
    preread_buffer_size 64k;
    preread_timeout 15s;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;
    proxy_pass \$rwins_backend;
}
NG
  cat >> "$LEGACY_MAIN" <<'NG'

# BEGIN RWINS LEGACY SNI EDGE
stream {
    include /etc/nginx/conf.d/rwins-stream/*.conf;
}
# END RWINS LEGACY SNI EDGE
NG
  if ! docker exec nginx-selfsteal nginx -t; then
    legacy_restore_before_reload "$snapshot/nginx.conf"
    die 'Nginx -t не прошёл; исходный конфиг автоматически восстановлен, reload НЕ делался'
  fi
  if ! docker exec nginx-selfsteal nginx -s reload; then
    legacy_restore_before_reload "$snapshot/nginx.conf"
    docker exec nginx-selfsteal nginx -s reload >/dev/null 2>&1 || true
    die 'Не удалось выполнить reload; конфиг восстановлен'
  fi
  legacy_record_state "$d" test "$snapshot"
  ok "Тестовый SNI Edge установлен, бэкап: $snapshot"
  legacy_test
}
legacy_test(){
  legacy_require
  local d mode port good bad
  [[ -f "$LEGACY_STREAM" ]] || die 'SNI Edge не подготовлен'
  d="$(legacy_domain)"; mode="$(legacy_mode)"
  case "$mode" in
    test) port=9444 ;;
    active) port=443 ;;
    *) die "Неизвестный режим SNI Edge: $mode" ;;
  esac
  printf '\nSNI Edge: %s; домен: %s; вход: TCP/%s\n' "$mode" "$d" "$port"
  if [[ "$mode" == test ]]; then
    need curl
    good="$(curl -ksS --noproxy '*' --connect-timeout 5 --max-time 12 \
      --resolve "$d:$port:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$d:$port/" 2>/dev/null || true)"
    bad="$(curl -ksS --noproxy '*' --connect-timeout 5 --max-time 12 \
      --resolve "sni-probe.invalid:$port:127.0.0.1" -o /dev/null -w '%{http_code}' "https://sni-probe.invalid:$port/" 2>/dev/null || true)"
    printf 'HTTPS свой SNI: HTTP %s\n' "${good:-FAIL}"
    printf 'HTTPS чужой SNI: HTTP %s\n' "${bad:-FAIL}"
    [[ "$good" =~ ^[123][0-9][0-9]$ && "$bad" =~ ^[123][0-9][0-9]$ ]] || warn 'Один из тестовых запросов не прошёл — не активируй Edge до устранения причины'
  fi
  echo 'Последние маршруты:'
  docker exec nginx-selfsteal sh -c 'tail -n 8 /var/log/nginx/rwins-edge.log 2>/dev/null || true'
  if [[ "$mode" == test ]]; then
    info 'Тестовый порт слушает только localhost:9444; внешние подключения не изменены.'
  fi
  warn 'Чужой SNI получит сертификат домена этой ноды — проверка имени в браузере не пройдёт.'
}
legacy_activate(){
  legacy_require
  local mode d snapshot
  mode="$(legacy_mode)"; [[ "$mode" == test ]] || die 'Сначала подготовь SNI Edge (пункт 4)'
  d="$(legacy_domain)"
  [[ -S /dev/shm/nginx.sock ]] || die 'Unix-сокет selfsteal отсутствует'
  ss -H -lnt '( sport = :1443 )' | grep -Fq '127.0.0.1:1443' || die 'REALITY ещё не слушает 127.0.0.1:1443'
  if legacy_port_busy 443; then
    ss -H -lntp '( sport = :443 )'
    die 'Порт 443/TCP ещё занят. Сначала назначь ТОЛЬКО этой ноде тестовый профиль REALITY localhost:1443.'
  fi
  if ! legacy_port_busy 9443; then die 'Нет HTTPS-сайта на 127.0.0.1:9443'; fi
  printf '\nАКТИВАЦИЯ SNI EDGE на %s\n' "$d"
  info '443/TCP теперь займёт существующий Docker Nginx, а REALITY останется на localhost:1443.'
  warn 'Автоматический откат не способен изменить Config Profile в Remnawave.'
  yesno 'Действительно переключить публичный TCP/443 на Nginx?' || return
  snapshot="$BACKUPS/legacy-edge-activate-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$snapshot"; cp -a "$LEGACY_STREAM" "$snapshot/edge.conf"
  # Adjust ONLY our generated file; preserve existing selfsteal and certificate configuration.
  sed -i -e 's/127\.0\.0\.1:443;/127.0.0.1:1443;/' \
         -e 's/listen 127\.0\.0\.1:9444;/listen 0.0.0.0:443;/' "$LEGACY_STREAM"
  if command -v ip >/dev/null 2>&1 && ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '; then
    sed -i '/listen 0.0.0.0:443;/a\    listen [::]:443 ipv6only=on;' "$LEGACY_STREAM"
  fi
  if ! grep -Fq 'listen 0.0.0.0:443;' "$LEGACY_STREAM" || \
     ! grep -Fq "$d 127.0.0.1:1443;" "$LEGACY_STREAM" || \
     ! docker exec nginx-selfsteal nginx -t; then
    cp -a "$snapshot/edge.conf" "$LEGACY_STREAM"
    die 'Не удалось подготовить production-конфиг. Тестовый конфиг восстановлен.'
  fi
  if ! docker exec nginx-selfsteal nginx -s reload; then
    cp -a "$snapshot/edge.conf" "$LEGACY_STREAM"
    docker exec nginx-selfsteal nginx -s reload >/dev/null 2>&1 || true
    die 'Reload не выполнился. Конфиг восстановлен, но Xray остаётся на localhost:1443.'
  fi
  legacy_record_state "$d" active "$snapshot"
  ok 'SNI Edge активирован на TCP/443.'
  info 'Проверь из сети клиента REALITY, браузер с правильным SNI и одновременно несколько подключений.'
  warn 'Если не работает: открой консоль провайдера, проверь nginx -t, логи и профиль; откат требует координации с Remnawave.'
}
legacy_disable(){
  legacy_require
  local mode tmp
  mode="$(legacy_mode)"
  [[ "$mode" != off ]] || { warn 'SNI Edge не был установлен'; return; }
  [[ "$mode" == test || "$mode" == active ]] || die 'Неизвестный конфиг, ручная проверка обязательна'
  if [[ "$mode" == active ]]; then
    warn 'Отключение SNI Edge освободит публичный 443/TCP. При REALITY на localhost:1443 клиенты потеряют доступ.'
    yesno 'Отключить активный Edge, понимая необходимость переключить профиль назад?' || return
  else
    yesno 'Удалить тестовую конфигурацию SNI Edge?' || return
  fi
  tmp="$(mktemp "$BACKUPS/legacy-main.XXXXXXXX")"
  cp -a "$LEGACY_MAIN" "$tmp"
  sed -i '/^# BEGIN RWINS LEGACY SNI EDGE$/,/^# END RWINS LEGACY SNI EDGE$/d' "$LEGACY_MAIN"
  # Cannot delete our stream file before successful config validation: first move aside.
  mv "$LEGACY_TLS" "$LEGACY_TLS.disabled"
  mv "$LEGACY_STREAM" "$LEGACY_STREAM.disabled"
  if ! docker exec nginx-selfsteal nginx -t || ! docker exec nginx-selfsteal nginx -s reload; then
    cp -a "$tmp" "$LEGACY_MAIN"
    mv "$LEGACY_TLS.disabled" "$LEGACY_TLS"
    mv "$LEGACY_STREAM.disabled" "$LEGACY_STREAM"
    docker exec nginx-selfsteal nginx -s reload >/dev/null 2>&1 || true
    die 'Удаление не прошло; конфигурация восстановлена'
  fi
  rm -f "$LEGACY_TLS.disabled" "$LEGACY_STREAM.disabled" "$LEGACY_STATE"
  ok 'SNI Edge удалён из старого nginx-selfsteal. Бэкапы сохранены.'
}

edge_prepare(){
  if legacy_container_exists; then legacy_prepare; else host_edge_prepare; fi
}
edge_activate(){
  if legacy_container_exists; then legacy_activate; else host_edge_activate; fi
}
edge_disable(){
  if legacy_container_exists; then legacy_disable; else host_edge_disable; fi
}
edge_test(){
  if legacy_container_exists; then legacy_test
  else
    warn 'Автотест предусмотрен для старого Docker selfsteal; проверь nginx -t и порты для хостового Nginx.'
  fi
}

fw_remove_rules(){
  local port="$1" tool ch
  for tool in iptables ip6tables; do
    if [[ $tool == iptables ]]; then ch="$FW_C4"; else ch="$FW_C6"; fi
    while "$tool" -w -C INPUT -p tcp --dport "$port" -m comment --comment "$FW_TAG" -j "$ch" 2>/dev/null; do
      "$tool" -w -D INPUT -p tcp --dport "$port" -m comment --comment "$FW_TAG" -j "$ch"
    done
    "$tool" -w -F "$ch" 2>/dev/null || true
    "$tool" -w -X "$ch" 2>/dev/null || true
  done
}
fw_apply(){
  local panel="$1" port="$2" prev=''
  valid_ipv4 "$panel" || die 'Неверный IPv4 панели'
  valid_port "$port" || die 'Неверный NODE_PORT'
  need iptables; need ip6tables
  [[ -f "$FW_CONF" ]] && { . "$FW_CONF"; prev="$PORT"; }
  [[ -z "$prev" ]] || fw_remove_rules "$prev"
  iptables -w -N "$FW_C4" 2>/dev/null || true
  ip6tables -w -N "$FW_C6" 2>/dev/null || true
  iptables -w -F "$FW_C4"
  ip6tables -w -F "$FW_C6"
  iptables -w -A "$FW_C4" -s "$panel/32" -j ACCEPT
  iptables -w -A "$FW_C4" -j DROP
  ip6tables -w -A "$FW_C6" -j DROP
  # Insert as the first INPUT rule to avoid existing broad ACCEPT for TCP/2222.
  iptables -w -I INPUT 1 -p tcp --dport "$port" -m comment --comment "$FW_TAG" -j "$FW_C4"
  ip6tables -w -I INPUT 1 -p tcp --dport "$port" -m comment --comment "$FW_TAG" -j "$FW_C6"
  printf 'PANEL=%s\nPORT=%s\n' "$panel" "$port" > "$FW_CONF"; chmod 600 "$FW_CONF"
}
fw_persist(){
  cat > "$FW_UNIT" <<'UNIT'
[Unit]
Description=Allow RemnaNode API only from designated panel IPv4
After=network-pre.target
Before=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rw-ins firewall-reapply
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable rw-ins-api-firewall.service >/dev/null
}
fw_menu(){
  command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1 || apt_install iptables
  need iptables; need ip6tables
  local p panel
  p="$(node_port)"
  printf '\nТекущий NODE_PORT (определён автоматически): %s\n' "$p"
  ask "Порт API ноды [$p]: "; p="${REPLY:-$p}"
  valid_port "$p" || die 'Неверный порт'
  ask 'Публичный IPv4 НОВОЙ панели (не домен): '; panel="$REPLY"
  valid_ipv4 "$panel" || die 'Неверный IPv4 панели'
  printf '\nРазрешённый IP: %s; порт: %s/TCP\n' "$panel" "$p"
  warn 'IPv6 на этом порту будет закрыт полностью. Если панель подключается через IPv6, этот режим не подходит.'
  yesno 'Применить и сохранить правило после перезагрузки?' || return
  fw_apply "$panel" "$p"
  fw_persist
  ok 'Правило включено. Проверь, что панель всё ещё видит ноду.'
}
fw_reapply(){
  [[ -r "$FW_CONF" ]] || die 'Конфигурация firewall не найдена'
  . "$FW_CONF"
  fw_apply "$PANEL" "$PORT"
}
fw_remove(){
  [[ -r "$FW_CONF" ]] || { warn 'Ограничение не настроено'; return; }
  . "$FW_CONF"
  yesno 'Удалить правила ограничения NODE_PORT?' || return
  systemctl disable rw-ins-api-firewall.service >/dev/null 2>&1 || true
  fw_remove_rules "$PORT"
  rm -f "$FW_CONF" "$FW_UNIT"
  systemctl daemon-reload
  ok 'Правила rw-ins удалены'
}
fw_status(){
  if [[ -f "$FW_CONF" ]]; then
    . "$FW_CONF"; printf 'NODE_PORT=%s PANEL=%s\n' "$PORT" "$PANEL"
  else
    echo 'Ограничение rw-ins ещё не включено'
  fi
  command -v iptables >/dev/null 2>&1 && iptables -S INPUT | grep -F "$FW_TAG" || true
  command -v ip6tables >/dev/null 2>&1 && ip6tables -S INPUT | grep -F "$FW_TAG" || true
  systemctl is-enabled rw-ins-api-firewall.service 2>/dev/null || true
}

status(){
  printf '\n===== rw-ins %s =====\n' "$VERSION"
  printf 'Версия образа для новых установок: %s\n' "$NODE_IMAGE"
  if legacy_container_exists && [[ -f "$LEGACY_SITE" ]]; then
    printf 'Домен старого selfsteal: %s\n' "$(legacy_domain)"
    printf 'Legacy SNI Edge: %s\n' "$(legacy_mode)"
  else
    printf 'Домен selfsteal: %s\n' "$(cat "$DOMAIN_FILE" 2>/dev/null || echo не настроен)"
  fi
  printf 'Nginx edge: '; [[ -f "$EDGE_ACTIVE" ]] && echo включён || echo выключен
  printf 'Unix-сокет: '; [[ -S /dev/shm/nginx.sock ]] && echo OK || echo отсутствует
  printf '\nКонтейнеры:\n'
  command -v docker >/dev/null 2>&1 && docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true
  printf '\nПорты:\n'
  command -v ss >/dev/null 2>&1 && ss -lntup | grep -E ':(443|8443|2222|1443|9443)[[:space:]]' || true
  printf '\nОграничение API:\n'; fw_status
  if [[ -f "$DOMAIN_FILE" ]]; then
    local d; d="$(cat "$DOMAIN_FILE")"
    openssl x509 -in "/etc/letsencrypt/live/$d/fullchain.pem" -noout -subject -enddate 2>/dev/null || true
  fi
}

warp_status(){
  if ip link show warp >/dev/null 2>&1; then
    ok 'Интерфейс warp существует'
    ip -d link show warp || true
  else
    warn 'Интерфейс warp не обнаружен. rw-ins пока не устанавливает Cloudflare WARP.'
  fi
  if command -v wg >/dev/null 2>&1; then wg show 2>/dev/null || true; fi
}
generate_sid(){ need openssl; printf 'Новый shortId (16 hex): %s\n' "$(openssl rand -hex 8)"; warn 'Он не добавлен в Config Profile. Для старых клиентов сначала оставь пустой SID, затем постепенно мигрируй.'; }
update_cli(){
  need curl
  warn 'Это обновит только команду rw-ins, не Docker и не Xray.'
  yesno "Загрузить текущую версию из $SELF_URL?" || return
  local tmp; tmp="$(mktemp "$STATE/update.XXXXXXXX")"
  curl -fsSL --retry 2 --max-time 30 "$SELF_URL" -o "$tmp"
  [[ $(wc -c < "$tmp") -gt 2000 ]] || { rm -f "$tmp"; die 'Загруженный файл слишком мал'; }
  bash -n "$tmp" || { rm -f "$tmp"; die 'Новая версия содержит синтаксическую ошибку'; }
  backup "$SELF"
  install -m 0755 "$tmp" "$SELF"
  rm -f "$tmp"
  ok 'rw-ins обновлён. Запусти rw-ins заново.'
}

menu(){
  root_only
  while true; do
    cat <<MENU

  ╔════════════════════════════════════════════════════╗
  ║   rw-ins — RemnaNode Installer  $VERSION       ║
  ╠════════════════════════════════════════════════════╣
  ║  1. Установить / проверить RemnaNode                 ║
  ║  2. Настроить Nginx Selfsteal + HTTPS               ║
  ║  3. Сертификаты Hysteria2 / XHTTP                   ║
  ║  4. Подготовить SNI Edge (авто Docker/host)         ║
  ║  5. Включить SNI Edge на тестовой ноде               ║
  ║  6. Отключить SNI Edge                              ║
  ║  7. Защитить NODE_PORT по IP панели                 ║
  ║  8. Удалить правила защиты NODE_PORT                ║
  ║  9. Проверка сервера и firewall                     ║
  ║ 10. Проверить продление сертификатов (dry-run)      ║
  ║ 11. Сгенерировать REALITY shortId                   ║
  ║ 12. Обновить сам rw-ins (по запросу)                ║
  ║ 13. Проверить WARP (без изменений)                 ║
  ║ 14. Проверить SNI Edge (без изменений)             ║
  ║  0. Выход                                           ║
  ╚════════════════════════════════════════════════════╝
MENU
    ask 'Выбери номер: '
    case "$REPLY" in
      1) install_node ;;
      2) selfsteal ;;
      3) hy2_certs ;;
      4) edge_prepare ;;
      5) edge_activate ;;
      6) edge_disable ;;
      7) fw_menu ;;
      8) fw_remove ;;
      9) status ;;
      10) need certbot; certbot renew --dry-run ;;
      11) generate_sid ;;
      12) update_cli ;;
      13) warp_status ;;
      14) edge_test ;;
      0|q|Q) return ;;
      *) warn 'Неизвестный пункт' ;;
    esac
  done
}
usage(){
  cat <<USAGE
rw-ins $VERSION
  menu               Interactive menu. Initial launch installs local CLI + Docker and offers RemnaNode setup.
  status             Show server status (read-only).
  edge-test          Test legacy SNI Edge routing from localhost.
  firewall-reapply   Non-interactive: restore configured NODE_PORT firewall rules (systemd service).
  self-install       Save this running script as /usr/local/bin/rw-ins.
  --version          Print version.

First run from GitHub:
  sudo bash -c "\$(curl -fsSL $SELF_URL)"
After that:
  sudo rw-ins

Existing nodes are NOT overwritten. Legacy Docker selfsteal is extended safely on loopback. Production cutover requires a temporary Config Profile on the selected node.
USAGE
}
main(){
  init
  case "${1:-menu}" in
    menu)
      local was_installed=1 invoked_from_cli=0
      [[ -f "$SELF" ]] || was_installed=0
      [[ "${BASH_SOURCE[0]:-}" == "$SELF" ]] && invoked_from_cli=1
      if (( ! invoked_from_cli )); then
        install_self
      fi
      if (( ! was_installed )); then
        ensure_docker
        if ! node_exists; then
          warn 'RemnaNode не обнаружена; для установки необходим SECRET_KEY из панели.'
          if yesno 'Установить ноду прямо сейчас?'; then install_node; fi
        fi
      fi
      menu
      ;;
    status) status ;;
    edge-test) edge_test ;;
    firewall-reapply) fw_reapply ;;
    self-install) install_self ;;
    --version) printf '%s\n' "$VERSION" ;;
    help|--help|-h) usage ;;
    *) usage; exit 2 ;;
  esac
}
main "$@"
