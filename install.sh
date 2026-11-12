#!/usr/bin/env bash
# RemnaNode standalone installer — no third-party Bash installers are downloaded/executed.
# Target: Ubuntu / Debian, Docker Compose v2, Remnawave Node.
# Supports: Node, Nginx Reality fallback, TLS for Hysteria2/XHTTP,
# optional staged SNI edge, diagnosis, rollback. Review before running.
set -Eeuo pipefail
umask 077

VERSION='0.1.0-preview'
NODE_DIR='/opt/remnanode'
SITE_DIR='/var/www/remna-selfsteal'
NGINX_SITE='/etc/nginx/sites-available/remna-selfsteal.conf'
NGINX_LINK='/etc/nginx/sites-enabled/remna-selfsteal.conf'
EDGE_DIR='/etc/nginx/remna-stream'
EDGE_ACTIVE="$EDGE_DIR/sni-edge.conf"
EDGE_PENDING="$EDGE_DIR/sni-edge.pending"
EDGE_STATE='/etc/remna-installer/edge.env'
CERT_COPY='/etc/xray-certs/hy2'
DOM_FILE='/etc/remna-installer/domain'
BACKUP_DIR='/var/backups/remna-installer'

log()  { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

error_handler() { warn "Ошибка на строке $1 (код $2). Проверь сообщения выше. Существующие файлы не удалены."; }
trap 'error_handler "$LINENO" "$?"' ERR

ask() {
  local label="$1" reply
  if [[ -r /dev/tty ]]; then
    printf '%s' "$label" >/dev/tty
    IFS= read -r reply </dev/tty || return 1
  else
    printf '%s' "$label" >&2
    IFS= read -r reply || return 1
  fi
  REPLY="$reply"
}
ask_secret() {
  local label="$1" reply
  [[ -r /dev/tty ]] || die 'Для ввода секретного ключа нужен интерактивный терминал.'
  printf '%s' "$label" >/dev/tty
  IFS= read -rs reply </dev/tty || return 1
  printf '\n' >/dev/tty
  REPLY="$reply"
}
confirm() { ask "$1 [y/N]: "; [[ "${REPLY,,}" == 'y' || "${REPLY,,}" == 'yes' || "${REPLY,,}" == 'д' ]]; }
root_only() { [[ $EUID -eq 0 ]] || die 'Нужен root: sudo bash install.sh'; }
need() { command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"; }
valid_domain() {
  local d="${1,,}"
  [[ ${#d} -le 253 && $d =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}
valid_ipv4() {
  local ip="$1" octet
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a parts <<< "$ip"
  for octet in "${parts[@]}"; do (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1; done
}
backup_file() {
  local src="$1" stamp
  [[ -e "$src" ]] || return 0
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR/$stamp"
  cp -a -- "$src" "$BACKUP_DIR/$stamp/$(basename "$src")"
  log "Резервная копия: $BACKUP_DIR/$stamp/$(basename "$src")"
}
preflight() {
  root_only
  [[ -f /etc/os-release ]] || die 'Не найдена /etc/os-release'
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == 'ubuntu' || "${ID:-}" == 'debian' ]] || die 'Поддерживаются только Ubuntu/Debian.'
  need apt-get; need systemctl; need openssl; need ss; need ip
  mkdir -p /etc/remna-installer "$BACKUP_DIR"
  chmod 700 /etc/remna-installer
}
install_packages() {
  local -a packages=("$@")
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y "${packages[@]}"
}
ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok 'Docker и Compose v2 уже доступны'
    return 0
  fi
  log 'Устанавливаю Docker из пакетных репозиториев (без curl | bash)'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  local compose_package=''
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then compose_package='docker-compose-v2'
  elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then compose_package='docker-compose-plugin'
  fi
  if [[ -n "$compose_package" ]]; then
    apt-get install -y docker.io "$compose_package"
  else
    # Official Docker apt repository; verifies signature through apt's signed-by keyring.
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg" \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    # shellcheck disable=SC1091
    source /etc/os-release
    local arch codename
    arch="$(dpkg --print-architecture)"; codename="${VERSION_CODENAME:-}"
    [[ -n "$codename" ]] || die 'Не удалось определить codename ОС.'
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
      "$arch" "$ID" "$codename" > /etc/apt/sources.list.d/docker-ce.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker
  docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 не установлен.'
}
install_node() {
  preflight
  ensure_docker
  if [[ -e "$NODE_DIR/docker-compose.yml" || -e "$NODE_DIR/compose.yaml" ]]; then
    warn "Найден существующий Compose в $NODE_DIR. Не перезаписываю его."
    return 0
  fi
  ask_secret 'Вставь SECRET_KEY ноды из панели Remnawave: '
  local secret="$REPLY"
  [[ -n "$secret" && "$secret" != *$'\n'* && "$secret" != *$'\r'* ]] || die 'Недопустимый SECRET_KEY'
  # Prevent dotenv injection. Keys from Remnawave are URL-safe strings.
  [[ "$secret" =~ ^[A-Za-z0-9._=-]+$ ]] || die 'SECRET_KEY содержит необычные символы; используй Compose, выданный панелью.'
  ask 'NODE_PORT [2222]: '
  local port="${REPLY:-2222}"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port >= 1 && port <= 65535 )) || die 'Недопустимый порт'
  mkdir -p "$NODE_DIR" "$CERT_COPY"
  chmod 700 "$NODE_DIR"
  printf 'SECRET_KEY=%s\n' "$secret" > "$NODE_DIR/.env"
  chmod 600 "$NODE_DIR/.env"
  unset secret REPLY
  cat > "$NODE_DIR/docker-compose.yml" <<YAML
services:
  remnanode:
    image: remnawave/node:latest
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
      - $CERT_COPY:$CERT_COPY:ro
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
YAML
  chmod 600 "$NODE_DIR/docker-compose.yml"
  ( cd "$NODE_DIR" && docker compose config --quiet && docker compose up -d )
  ok 'RemnaNode запущена. Назначь Config Profile в панели.'
  warn 'Проверяй, что rw-core может прочитать приватный ключ TLS внутри контейнера: docker exec remnanode test -r /etc/xray-certs/hy2/privkey.pem'
  warn "Порт $port пока публичный. Закрой его по IP панели ПОСЛЕ переезда панели."
  warn 'Если профиль содержит XHTTP/Hysteria2, сначала настрой TLS-сертификат.'
}

ensure_certificate() {
  local domain="$1" email="$2" certdir="/etc/letsencrypt/live/$domain"
  if [[ -s "$certdir/fullchain.pem" && -s "$certdir/privkey.pem" ]]; then
    ok "Сертификат уже есть: $certdir"
    return 0
  fi
  if ss -H -ltn '( sport = :80 )' | grep -q .; then
    die 'Порт TCP/80 занят. Для HTTP-01 нужен свободный порт; действующие веб-сервисы автоматически не останавливаю.'
  fi
  install_packages certbot ca-certificates
  log "Certbot HTTP-01 для $domain. DNS A-запись должна вести на этот сервер, TCP/80 открыт."
  certbot certonly --standalone --preferred-challenges http --non-interactive --agree-tos \
    --email "$email" --keep-until-expiring --key-type ecdsa -d "$domain"
  [[ -s "$certdir/fullchain.pem" ]] || die 'Сертификат не создан.'
}

write_cert_hook() {
  local domain="$1"
  local hook='/etc/letsencrypt/renewal-hooks/deploy/remna-sync.sh'
  mkdir -p "$(dirname "$hook")"
  cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ -s /etc/remna-installer/domain ]] || exit 0
domain="$(cat /etc/remna-installer/domain)"
certdir="/etc/letsencrypt/live/$domain"
[[ -r "$certdir/fullchain.pem" && -r "$certdir/privkey.pem" ]] || exit 0
# On deploy hook, act only for selected certificate, unless run manually without RENEWED_LINEAGE.
if [[ -n "${RENEWED_LINEAGE:-}" && "${RENEWED_LINEAGE%/}" != "$certdir" ]]; then exit 0; fi
out=/etc/xray-certs/hy2
mkdir -p "$out"
changed=0
if ! cmp -s "$certdir/fullchain.pem" "$out/fullchain.pem"; then
  install -m 0644 "$certdir/fullchain.pem" "$out/fullchain.pem"
  changed=1
fi
if ! cmp -s "$certdir/privkey.pem" "$out/privkey.pem"; then
  install -m 0600 "$certdir/privkey.pem" "$out/privkey.pem"
  changed=1
fi
if (( changed )); then
  systemctl is-active --quiet nginx && systemctl reload nginx || true
  if command -v docker >/dev/null && docker ps --format '{{.Names}}' | grep -Fxq remnanode; then
    docker restart remnanode >/dev/null
  fi
fi
HOOK
  chmod 700 "$hook"
  # Also sync now. Certbot's deploy hook only runs when the certificate is obtained/renewed.
  "$hook"
  systemctl enable --now certbot.timer >/dev/null 2>&1 || warn 'Проверь certbot.timer.'
}

install_selfsteal() {
  preflight
  if command -v docker >/dev/null && docker ps -a --format '{{.Names}}' | grep -Fxq nginx-selfsteal; then
    die 'Обнаружен nginx-selfsteal в Docker. Автоматическую миграцию не делаю во избежание конфликтов Unix-сокета.'
  fi
  ask 'Домен текущей ноды, например de.veloragrid.site: '
  local domain="${REPLY,,}"
  valid_domain "$domain" || die 'Некорректный домен'
  ask 'Email для Let’s Encrypt: '
  local email="$REPLY"
  [[ "$email" == *@*.* && "$email" != *' '* ]] || die 'Некорректный email'
  local oldconf=""
  if [[ -e "$NGINX_SITE" ]]; then
    warn "Конфигурация $NGINX_SITE уже существует."
    confirm 'Перезаписать её с резервной копией?' || return 0
    backup_file "$NGINX_SITE"
    oldconf="$(mktemp /tmp/remna-selfsteal-old.XXXXXX)"
    cp -a "$NGINX_SITE" "$oldconf"
  fi
  # Certificate obtained before Nginx, to avoid monopolizing TCP/80 during first issuance.
  ensure_certificate "$domain" "$email"
  install_packages nginx libnginx-mod-stream
  mkdir -p "$SITE_DIR" /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/remna-installer
  printf '%s\n' "$domain" > "$DOM_FILE"; chmod 600 "$DOM_FILE"
  cat > "$SITE_DIR/index.html" <<'HTML'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Home</title><style>body{background:#f6f7fb;color:#283244;font:16px system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0}.c{background:white;max-width:680px;padding:48px;border:1px solid #e6e9ef;border-radius:18px;box-shadow:0 14px 60px #27344b14}h1{font-size:30px;margin:0 0 14px}p{line-height:1.7;color:#607087}</style></head><body><main class="c"><h1>Welcome</h1><p>This service is currently available. Please check back later for updates.</p></main></body></html>
HTML
  chmod 644 "$SITE_DIR/index.html"
  cat > "$NGINX_SITE" <<CONF
# Generated by remnanode-installer $VERSION. Reality fallback + plain HTTPS target.
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 127.0.0.1:9443 ssl http2;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol http2;
    server_name $domain;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    root $SITE_DIR;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
CONF
  chmod 644 "$NGINX_SITE"
  ln -sfn "$NGINX_SITE" "$NGINX_LINK"
  # Do not change unrelated sites; test before reload/restart.
  if ! nginx -t; then
    if [[ -n "$oldconf" ]]; then
      cp -a "$oldconf" "$NGINX_SITE"
    else
      rm -f "$NGINX_SITE" "$NGINX_LINK"
    fi
    rm -f "${oldconf:-}"
    die 'Nginx config invalid: restored previous site (if any).'
  fi
  [[ -z "$oldconf" ]] || rm -f "$oldconf"
  systemctl enable --now nginx
  systemctl reload nginx
  write_cert_hook "$domain"
  [[ -S /dev/shm/nginx.sock ]] || die 'Unix-сокет nginx не создан. Проверь systemctl status nginx.'
  ok "Selfsteal готов для $domain. REALITY target: /dev/shm/nginx.sock, xver: 1."
  warn 'Пока публичный 443/TCP по-прежнему принадлежит Xray. SNI edge не включён.'
  warn 'Если приватный ключ в контейнере не читается, проверь UID/GID образа RemnaNode; не делай ключ world-readable.'
  warn 'Если установлена старая RemnaNode, убедись, что /dev/shm смонтирован в контейнер.'
}

ensure_edge_include() {
  local marker='include /etc/nginx/remna-stream/*.conf;'
  if ! grep -Fxq "$marker" /etc/nginx/nginx.conf; then
    backup_file /etc/nginx/nginx.conf
    printf '\n# Managed by RemnaNode installer — stream SNI edge.\n%s\n' "$marker" >> /etc/nginx/nginx.conf
  fi
}

prepare_edge() {
  preflight
  need nginx
  [[ -s "$DOM_FILE" ]] || die 'Сначала установи selfsteal.'
  [[ -f "$NGINX_SITE" ]] || die 'Не найден selfsteal Nginx конфиг.'
  [[ -S /dev/shm/nginx.sock ]] || die 'Unix-сокет отсутствует; сначала почини selfsteal.'
  [[ ! -f "$EDGE_ACTIVE" ]] || die 'SNI edge уже активен.'
  local domain ipaddr addr cnt
  domain="$(cat "$DOM_FILE")"
  ask 'Локальный IPv4 сервера (должен быть назначен сетевому интерфейсу): '
  ipaddr="$REPLY"
  valid_ipv4 "$ipaddr" || die 'Некорректный IP'
  ip -4 -o addr show scope global | awk '{split($4,a,"/");print a[1]}' | grep -Fxq "$ipaddr" \
    || die 'Этот IP не назначен интерфейсу сервера. NAT-схема пока не поддерживается.'
  mkdir -p "$EDGE_DIR"
  # Importantly: stream ingress does not send PROXY protocol to Xray;
  # Reality's existing xver=1 sends PROXY v1 only to Unix socket fallback.
  cat > "$EDGE_PENDING" <<CONF
# Stage only. Activate after REALITY binds 127.0.0.1:443 on THIS node.
stream {
    map \$ssl_preread_server_name \$remna_backend {
        $domain 127.0.0.1:443;
        default 127.0.0.1:9443;
    }
    server {
        listen $ipaddr:443;
        ssl_preread on;
        preread_buffer_size 64k;
        preread_timeout 15s;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        proxy_pass \$remna_backend;
    }
}
CONF
  chmod 644 "$EDGE_PENDING"
  # Validate by including the ordinary main config plus staged stream config as top-level context.
  local tmp
  tmp="$(mktemp /tmp/remna-nginx-check.XXXXXX)"
  printf 'include /etc/nginx/nginx.conf;\ninclude %s;\n' "$EDGE_PENDING" > "$tmp"
  if ! nginx -p /etc/nginx/ -t -c "$tmp"; then
    rm -f "$tmp"
    die 'Проверка синтаксиса SNI edge не пройдена. Рабочий Nginx не изменён.'
  fi
  rm -f "$tmp"
  ok "Подготовлено: $EDGE_PENDING (SNI $domain → Xray; прочие → обычный HTTPS)"
  warn 'НЕ АКТИВИРОВАНО. В отдельном тестовом профиле Remnawave переведи REALITY listen на 127.0.0.1:443 ТОЛЬКО для этой ноды.'
  warn 'Не меняй общий профиль сразу для всех нод!'
  warn 'Для внешнего IPv6 этот конфиг ничего не меняет. Отключи/обработай AAAA отдельно.'
}

activate_edge() {
  preflight
  [[ -f "$EDGE_PENDING" ]] || die 'Сначала выполни подготовку SNI edge.'
  [[ ! -e "$EDGE_ACTIVE" ]] || die 'SNI edge уже активирован.'
  need ss; need nginx
  local sockets line
  sockets="$(ss -H -lnt '( sport = :443 )' | awk '{print $4}')"
  grep -Fxq '127.0.0.1:443' <<< "$sockets" \
    || die 'Xray на 127.0.0.1:443 не слушает. Сначала переключи эту ноду на тестовый профиль.'
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == '127.0.0.1:443' ]] && continue
    die "На 443/TCP есть другой listener: $line — проверь перед активацией."
  done <<< "$sockets"
  confirm 'Активировать публичный Nginx stream :443 на ЭТОЙ ноде?' || return 0
  ensure_edge_include
  cp -a "$EDGE_PENDING" "$EDGE_ACTIVE"
  if ! nginx -t || ! systemctl reload nginx; then
    rm -f "$EDGE_ACTIVE"
    nginx -t && systemctl reload nginx || true
    die 'Активация провалилась: конфигурация stream удалена. Xray остался на loopback.'
  fi
  printf 'activated=%s\n' "$(date -Is)" > "$EDGE_STATE"
  ok 'SNI edge активирован. Проверь REALITY, сайт и чужой SNI с внешней машины.'
  warn 'Известный риск: nginx ssl_preread + параллельные REALITY ClientHello могут зависать на некоторых версиях Xray.'
  warn 'Чужой SNI получает реальный HTTPS-сайт, но его сертификат не совпадает с чужим именем — это ожидаемо.'
  warn 'Откат отключит публичный 443; восстанови Xray bind после освобождения порта.'
}

disable_edge() {
  preflight
  [[ -f "$EDGE_ACTIVE" ]] || { warn 'SNI edge не активен.'; return 0; }
  warn 'Отключение Nginx stream сделает REALITY недоступным извне, пока он слушает 127.0.0.1.'
  confirm 'Точно отключить SNI edge?' || return 0
  backup_file "$EDGE_ACTIVE"
  rm -f "$EDGE_ACTIVE"
  if ! nginx -t || ! systemctl reload nginx; then
    die 'Не удалось перезагрузить Nginx после отключения. Проверь nginx -t.'
  fi
  rm -f "$EDGE_STATE"
  ok 'Публичный stream слушатель отключён. Теперь можно вернуть Xray на 0.0.0.0:443.'
}

show_status() {
  printf '=== RemnaNode Installer %s ===\n' "$VERSION"
  printf '\nPorts TCP/UDP:\n'
  ss -lntup | grep -E '(:443|:8443|:2222|:9443)' || true
  printf '\nContainers:\n'
  if command -v docker >/dev/null 2>&1; then docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true; fi
  printf '\nSelfsteal:\n'
  [[ -s "$DOM_FILE" ]] && { printf 'Domain: '; cat "$DOM_FILE"; } || echo 'not configured by this installer'
  [[ -S /dev/shm/nginx.sock ]] && echo 'Unix socket: OK' || echo 'Unix socket: absent'
  if command -v nginx >/dev/null; then nginx -t || true; fi
  [[ -f "$EDGE_ACTIVE" ]] && echo 'SNI edge: ACTIVE' || echo 'SNI edge: inactive'
  [[ -f "$EDGE_PENDING" ]] && echo "Pending: $EDGE_PENDING" || true
  if [[ -s "$DOM_FILE" ]]; then
    local d; d="$(cat "$DOM_FILE")"
    openssl x509 -in "/etc/letsencrypt/live/$d/fullchain.pem" -noout -subject -enddate 2>/dev/null || true
  fi
  if ip link show warp >/dev/null 2>&1; then echo 'WARP interface: exists'; else echo 'WARP interface: not present'; fi
}

update_node() {
  preflight
  need docker
  [[ -f "$NODE_DIR/docker-compose.yml" ]] || die 'Compose ноды не найден.'
  backup_file "$NODE_DIR/docker-compose.yml"
  (cd "$NODE_DIR" && docker compose pull && docker compose up -d)
  ok 'Образ ноды обновлён.'
}

shortid() {
  need openssl
  printf 'Новый shortId REALITY (16 hex): %s\n' "$(openssl rand -hex 8)"
  warn 'Добавь ID в REALITY shortIds профиля и настрой выдачу в Host/подписках. Текущий профиль не изменён.'
}

help_text() {
  cat <<EOF
RemnaNode standalone installer $VERSION
Использование: sudo bash install.sh [menu|node|selfsteal|edge-prepare|edge-activate|edge-disable|status|update|shortid|help]
Новый скрипт не переписывает существующий docker-compose.yml и не запускает чужие Bash-скрипты.
Важно: это отдельная реализация (preview), а не точная копия предыдущего установщика.
EOF
}
menu() {
  while true; do
    printf '\n===== RemnaNode installer %s =====\n' "$VERSION"
    printf ' 1) Установить RemnaNode (Docker + Compose)\n'
    printf ' 2) Настроить Nginx selfsteal + SSL + сертификаты для HY2/XHTTP\n'
    printf ' 3) Подготовить SNI edge (БЕЗ переключения трафика)\n'
    printf ' 4) Активировать SNI edge на тестовой ноде\n'
    printf ' 5) Отключить SNI edge\n'
    printf ' 6) Диагностика\n'
    printf ' 7) Обновить образ RemnaNode\n'
    printf ' 8) Сгенерировать shortId\n'
    printf ' 0) Выход\n'
    ask 'Выбор: '
    case "$REPLY" in
      1) install_node;;
      2) install_selfsteal;;
      3) prepare_edge;;
      4) activate_edge;;
      5) disable_edge;;
      6) show_status;;
      7) update_node;;
      8) shortid;;
      0|q|Q) return;;
      *) warn 'Неизвестный пункт';;
    esac
  done
}

case "${1:-menu}" in
  menu) menu;;
  node) install_node;;
  selfsteal) install_selfsteal;;
  edge-prepare) prepare_edge;;
  edge-activate) activate_edge;;
  edge-disable) disable_edge;;
  status) show_status;;
  update) update_node;;
  shortid) shortid;;
  help|--help|-h) help_text;;
  --version) echo "$VERSION";;
  *) help_text; exit 2;;
esac
