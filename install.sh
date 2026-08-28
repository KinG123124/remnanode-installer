#!/bin/bash

set -e

INSTALLER_BUILD="2026-08-28-hy2-auto-cert-v3"

if [ "$EUID" -ne 0 ]; then
  echo "❌ Ошибка: Пожалуйста, запустите этот скрипт через sudo"
  exit 1
fi

echo "🚀 Добро пожаловать в автоматический установщик Remnanode!"
echo "🧩 Версия сборки: $INSTALLER_BUILD"
echo "------------------------------------------------------"

if command -v docker &> /dev/null; then
  echo "✅ Docker уже установлен в системе. Пропускаем этот шаг."
else
  echo "📦 Docker не найден. Начинаем установку официального пакета..."
  curl -fsSL https://get.docker.com | sh
  echo "✅ Docker успешно установлен!"
fi

echo "------------------------------------------------------"

TARGET_DIR="/opt/remnanode"
CONFIG_PATH="$TARGET_DIR/docker-compose.yml"

HY2_CERT_ROOT="$TARGET_DIR/certs"
HY2_CERT_DIR="$HY2_CERT_ROOT/hy2"
HY2_VOLUME="/opt/remnanode/certs:/etc/xray-certs:ro"

ACME_HOME="/root/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
HY2_RENEW_WRAPPER="/usr/local/sbin/remnanode-hy2-renew"
HY2_SYNC_SCRIPT="/usr/local/sbin/remnanode-hy2-cert-sync"
HY2_SYNC_CRON="/etc/cron.d/remnanode-hy2-cert-sync"
HY2_RENEW_CRON="/etc/cron.d/remnanode-hy2-cert-renew"

# 8443 специально не используем: он зарезервирован под XHTTP.
ACME_FALLBACK_PORTS=(9443 10443 18443 28443 38443)

SHOULD_INSTALL=true


ensure_package() {
  local cmd="$1"
  local pkg="$2"

  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  echo "📦 Устанавливаем $pkg..."

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$pkg"
  else
    echo "❌ Не удалось определить пакетный менеджер."
    return 1
  fi
}


ensure_compose_volume() {
  local volume="$1"

  if grep -Fq -- "- $volume" "$CONFIG_PATH"; then
    echo "✅ Volume для Hysteria2 уже есть в docker-compose.yml."
    return 0
  fi

  local backup="${CONFIG_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
  cp "$CONFIG_PATH" "$backup"

  if grep -Eq '^    volumes:[[:space:]]*$' "$CONFIG_PATH"; then
    sed -i "/^    volumes:[[:space:]]*$/a\\      - $volume" "$CONFIG_PATH"
  else
    sed -i "/^    network_mode:/i\\    volumes:\n      - $volume" "$CONFIG_PATH"
  fi

  if docker compose -f "$CONFIG_PATH" config >/dev/null 2>&1; then
    echo "✅ Добавлен Docker volume:"
    echo "   $volume"
  else
    echo "❌ docker-compose.yml стал невалидным. Восстанавливаем резервную копию."
    mv "$backup" "$CONFIG_PATH"
    return 1
  fi
}


certificate_matches_domain() {
  local cert="$1"
  local domain="$2"

  [ -f "$cert" ] || return 1

  if openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}


copy_cert_to_hy2() {
  local fullchain="$1"
  local privkey="$2"

  mkdir -p "$HY2_CERT_DIR"
  install -m 0644 -T "$fullchain" "$HY2_CERT_DIR/fullchain.pem"
  install -m 0600 -T "$privkey" "$HY2_CERT_DIR/privkey.pem"
}


setup_source_sync() {
  local source_fullchain="$1"
  local source_privkey="$2"

  cat > "$HY2_SYNC_SCRIPT" <<EOF
#!/bin/bash
set -e

SRC_CERT="$source_fullchain"
SRC_KEY="$source_privkey"
DST_CERT="$HY2_CERT_DIR/fullchain.pem"
DST_KEY="$HY2_CERT_DIR/privkey.pem"

[ -f "\$SRC_CERT" ] || exit 0
[ -f "\$SRC_KEY" ] || exit 0

changed=0

if [ ! -f "\$DST_CERT" ] || ! cmp -s "\$SRC_CERT" "\$DST_CERT"; then
  install -m 0644 -T "\$SRC_CERT" "\$DST_CERT"
  changed=1
fi

if [ ! -f "\$DST_KEY" ] || ! cmp -s "\$SRC_KEY" "\$DST_KEY"; then
  install -m 0600 -T "\$SRC_KEY" "\$DST_KEY"
  changed=1
fi

if [ "\$changed" -eq 1 ] && docker ps --format '{{.Names}}' | grep -qx remnanode; then
  docker restart remnanode >/dev/null
fi
EOF

  chmod 0755 "$HY2_SYNC_SCRIPT"

  cat > "$HY2_SYNC_CRON" <<EOF
# Remnanode Hysteria2 certificate sync
17 */6 * * * root $HY2_SYNC_SCRIPT >/dev/null 2>&1
EOF
  chmod 0644 "$HY2_SYNC_CRON"

  echo "✅ Добавлена автоматическая синхронизация сертификата каждые 6 часов."
}


install_acme_sh() {
  if [ -x "$ACME_BIN" ]; then
    echo "✅ acme.sh уже установлен."
    "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    return 0
  fi

  echo "📦 Устанавливаем acme.sh..."
  curl -fsSL https://get.acme.sh -o /tmp/acme-install.sh

  local random_email="hy2-$(date +%s)@localhost.local"
  sh /tmp/acme-install.sh email="$random_email"
  rm -f /tmp/acme-install.sh

  if [ ! -x "$ACME_BIN" ]; then
    echo "❌ Не удалось установить acme.sh."
    return 1
  fi

  "$ACME_BIN" --set-default-ca --server letsencrypt
  echo "✅ acme.sh установлен."
}


find_free_acme_port() {
  local port

  for port in "${ACME_FALLBACK_PORTS[@]}"; do
    if ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
      echo "$port"
      return 0
    fi
  done

  return 1
}


add_acme_redirect() {
  local port="$1"

  iptables -t nat -I PREROUTING 1 -p tcp --dport 443 -j REDIRECT --to-port "$port"
  iptables -t nat -I OUTPUT 1 -p tcp --dport 443 -o lo -j REDIRECT --to-port "$port" 2>/dev/null || true
}


remove_acme_redirect() {
  local port="$1"

  iptables -t nat -D PREROUTING -p tcp --dport 443 -j REDIRECT --to-port "$port" 2>/dev/null || true
  iptables -t nat -D OUTPUT -p tcp --dport 443 -o lo -j REDIRECT --to-port "$port" 2>/dev/null || true
}


issue_hy2_certificate() {
  local domain="$1"

  ensure_package openssl openssl
  ensure_package socat socat
  ensure_package iptables iptables

  install_acme_sh

  local acme_port
  if ! acme_port="$(find_free_acme_port)"; then
    echo "❌ Не найден свободный порт для ACME."
    echo "Проверялись: ${ACME_FALLBACK_PORTS[*]}"
    return 1
  fi

  mkdir -p "$HY2_CERT_DIR"

  echo "🔐 Выпускаем Let's Encrypt сертификат для $domain..."
  echo "ℹ️ TLS-ALPN challenge: внешний TCP/443 → временный локальный порт $acme_port"
  echo "ℹ️ TCP/8443 не трогаем — он остается под XHTTP."

  add_acme_redirect "$acme_port"

  local rc=0
  set +e
  "$ACME_BIN" \
    --issue \
    --standalone \
    -d "$domain" \
    --key-file "$HY2_CERT_DIR/privkey.pem" \
    --fullchain-file "$HY2_CERT_DIR/fullchain.pem" \
    --alpn \
    --tlsport "$acme_port" \
    --server letsencrypt \
    --force
  rc=$?
  set -e

  remove_acme_redirect "$acme_port"

  if [ "$rc" -ne 0 ] || [ ! -s "$HY2_CERT_DIR/fullchain.pem" ] || [ ! -s "$HY2_CERT_DIR/privkey.pem" ]; then
    echo "❌ Выпустить сертификат не удалось."
    echo "Проверьте DNS домена и доступность TCP/443 извне."
    return 1
  fi

  chmod 0644 "$HY2_CERT_DIR/fullchain.pem"
  chmod 0600 "$HY2_CERT_DIR/privkey.pem"

  if ! certificate_matches_domain "$HY2_CERT_DIR/fullchain.pem" "$domain"; then
    echo "❌ Полученный сертификат не соответствует домену $domain."
    return 1
  fi

  cat > "$HY2_RENEW_WRAPPER" <<EOF
#!/bin/bash
set -e

ACME_BIN="$ACME_BIN"
ACME_HOME="$ACME_HOME"
TLS_PORT="$acme_port"

cleanup() {
  iptables -t nat -D PREROUTING -p tcp --dport 443 -j REDIRECT --to-port "\$TLS_PORT" 2>/dev/null || true
  iptables -t nat -D OUTPUT -p tcp --dport 443 -o lo -j REDIRECT --to-port "\$TLS_PORT" 2>/dev/null || true
}

trap cleanup EXIT

iptables -t nat -I PREROUTING 1 -p tcp --dport 443 -j REDIRECT --to-port "\$TLS_PORT"
iptables -t nat -I OUTPUT 1 -p tcp --dport 443 -o lo -j REDIRECT --to-port "\$TLS_PORT" 2>/dev/null || true

"\$ACME_BIN" --cron --home "\$ACME_HOME"

if docker ps --format '{{.Names}}' | grep -qx remnanode; then
  docker restart remnanode >/dev/null
fi
EOF

  chmod 0755 "$HY2_RENEW_WRAPPER"

  cat > "$HY2_RENEW_CRON" <<EOF
# Remnanode Hysteria2 Let's Encrypt renewal
27 4 * * * root $HY2_RENEW_WRAPPER >/var/log/remnanode-hy2-renew.log 2>&1
EOF
  chmod 0644 "$HY2_RENEW_CRON"

  echo "✅ Сертификат выпущен."
  echo "✅ Автопродление настроено."
}


configure_hysteria_certificates() {
  echo "------------------------------------------------------"
  echo "🔐 Дополнительная настройка сертификатов для Hysteria2"
  echo
  echo "После настройки общий Xray-профиль использует:"
  echo "  /etc/xray-certs/hy2/fullchain.pem"
  echo "  /etc/xray-certs/hy2/privkey.pem"
  echo

  read -p "Введите домен Hysteria2: " HY2_DOMAIN

  if [ -z "$HY2_DOMAIN" ]; then
    echo "❌ Домен не указан. Настройка Hysteria2 пропущена."
    return 0
  fi

  ensure_package openssl openssl

  local source_cert=""
  local source_key=""

  # 1. Переиспользуем сертификат Nginx Selfsteal, если он подходит домену.
  if [ -f "/opt/nginx-selfsteal/ssl/fullchain.crt" ] \
     && [ -f "/opt/nginx-selfsteal/ssl/private.key" ] \
     && certificate_matches_domain "/opt/nginx-selfsteal/ssl/fullchain.crt" "$HY2_DOMAIN"; then

    source_cert="/opt/nginx-selfsteal/ssl/fullchain.crt"
    source_key="/opt/nginx-selfsteal/ssl/private.key"

    echo "✅ Найден подходящий сертификат Nginx Selfsteal."
    echo "♻️ Переиспользуем его для Hysteria2."

  # 2. Если есть Certbot-сертификат — используем его.
  elif [ -f "/etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem" ] \
       && [ -f "/etc/letsencrypt/live/$HY2_DOMAIN/privkey.pem" ] \
       && certificate_matches_domain "/etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem" "$HY2_DOMAIN"; then

    source_cert="/etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem"
    source_key="/etc/letsencrypt/live/$HY2_DOMAIN/privkey.pem"

    echo "✅ Найден существующий сертификат Certbot."
    echo "♻️ Переиспользуем его для Hysteria2."
  fi

  if [ -n "$source_cert" ]; then
    mkdir -p "$HY2_CERT_DIR"
    copy_cert_to_hy2 "$source_cert" "$source_key"
    setup_source_sync "$source_cert" "$source_key"
  else
    echo "ℹ️ Готового сертификата для $HY2_DOMAIN нет."
    echo "🚀 Сейчас выпустим новый сертификат Let's Encrypt автоматически."

    if ! issue_hy2_certificate "$HY2_DOMAIN"; then
      echo "❌ Настройка Hysteria2 не завершена."
      return 0
    fi
  fi

  ensure_compose_volume "$HY2_VOLUME"

  echo "🔄 Пересоздаем Remnanode с новым volume..."
  cd "$TARGET_DIR"
  docker compose up -d --force-recreate

  echo
  echo "✅ Настройка сертификатов Hysteria2 завершена."
  echo
  echo "На хосте:"
  echo "  $HY2_CERT_DIR/fullchain.pem"
  echo "  $HY2_CERT_DIR/privkey.pem"
  echo
  echo "В Xray:"
  echo '  "certificates": ['
  echo '    {'
  echo '      "keyFile": "/etc/xray-certs/hy2/privkey.pem",'
  echo '      "certificateFile": "/etc/xray-certs/hy2/fullchain.pem"'
  echo '    }'
  echo '  ]'
}


if [ -f "$CONFIG_PATH" ]; then
  echo "⚠️ Внимание: Обнаружена уже установленная нода в $TARGET_DIR"
  read -p "Хотите ПОЛНОСТЬЮ удалить старую ноду и установить её заново? [y/N]: " REINSTALL

  if [[ "$REINSTALL" =~ ^[Yy]$ ]]; then
    echo "🗑️ Удаляем старый контейнер и конфигурацию..."
    cd "$TARGET_DIR"
    docker compose down --remove-orphans || true
    rm -f docker-compose.yml
    echo "✅ Старая нода успешно удалена."
  else
    echo "⏭️ Переустановка отменена. Оставляем текущие настройки без изменений."
    SHOULD_INSTALL=false
    cd "$TARGET_DIR"
  fi
fi


if [ "$SHOULD_INSTALL" = true ]; then
  echo "📁 Настройка новой рабочей директории..."
  mkdir -p "$TARGET_DIR"
  cd "$TARGET_DIR"

  echo "------------------------------------------------------"
  echo "🔑 Шаг создания конфигурации"
  read -p "Введите ваш SECRET_KEY (вставьте ключ и нажмите Enter): " SECRET_KEY

  if [ -z "$SECRET_KEY" ]; then
    echo "⚠️ Предупреждение: Вы оставили SECRET_KEY пустым!"
  fi

  echo "📝 Создаем файл docker-compose.yml..."
  cat << EOF > docker-compose.yml
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=$SECRET_KEY
EOF
  echo "✅ Новый файл конфигурации успешно создан."
fi


echo "------------------------------------------------------"

echo "⚡ Запуск контейнера Remnanode..."
cd "$TARGET_DIR"
docker compose up -d

echo "------------------------------------------------------"

read -p "Хотите установить скрипт автоматической настройки selfsteal? [y/N]: " CONFIRM_STEAL
if [[ "$CONFIRM_STEAL" =~ ^[Yy]$ ]]; then
  echo "⏳ Скачивание и запуск selfsteal..."
  curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh -o /tmp/selfsteal.sh
  bash /tmp/selfsteal.sh @ --nginx install
  rm -f /tmp/selfsteal.sh
  echo "✅ Настройка selfsteal завершена."
else
  echo "⏭️ Установка selfsteal пропущена."
fi

echo "------------------------------------------------------"

read -p "Хотите провести дополнительную настройку сертификатов для Hysteria2? [y/N]: " CONFIRM_HY2
if [[ "$CONFIRM_HY2" =~ ^[Yy]$ ]]; then
  configure_hysteria_certificates
else
  echo "⏭️ Настройка сертификатов Hysteria2 пропущена."
fi

echo "------------------------------------------------------"

read -p "Хотите установить скрипт автоматической настройки Cloudflare WARP? [y/N]: " CONFIRM_WARP
if [[ "$CONFIRM_WARP" =~ ^[Yy]$ ]]; then
  echo "⏳ Скачивание и запуск Cloudflare WARP..."
  curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh -o /tmp/warp_install.sh
  bash /tmp/warp_install.sh
  rm -f /tmp/warp_install.sh
  echo "✅ Настройка Cloudflare WARP завершена."
else
  echo "⏭️ Установка Cloudflare WARP пропущена."
fi

echo "------------------------------------------------------"
echo "🎉 Все выбранные этапы успешно выполнены!"
echo "👉 Проверить статус ноды: cd /opt/remnanode && docker compose ps"
