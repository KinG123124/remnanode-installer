#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
  echo "❌ Ошибка: Пожалуйста, запустите этот скрипт через sudo"
  exit 1
fi

echo "🚀 Добро пожаловать в автоматический установщик Remnanode!"
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
HY2_CONTAINER_CERT_ROOT="/etc/xray-certs"
HY2_VOLUME="/opt/remnanode/certs:/etc/xray-certs:ro"
HY2_SYNC_SCRIPT="/usr/local/sbin/remnanode-sync-hy2-cert"
HY2_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/remnanode-hy2-cert.sh"

SHOULD_INSTALL=true

ensure_compose_volume() {
  local volume="$1"

  if grep -Fq -- "- $volume" "$CONFIG_PATH"; then
    echo "✅ Volume уже присутствует в docker-compose.yml:"
    echo "   $volume"
    return 0
  fi

  if grep -Eq '^    volumes:[[:space:]]*$' "$CONFIG_PATH"; then
    sed -i "/^    volumes:[[:space:]]*$/a\\      - $volume" "$CONFIG_PATH"
  else
    sed -i "/^    network_mode:/i\\    volumes:\n      - $volume" "$CONFIG_PATH"
  fi

  echo "✅ Volume добавлен в docker-compose.yml:"
  echo "   $volume"
}

configure_hysteria_certificates() {
  echo "------------------------------------------------------"
  echo "🔐 Дополнительная настройка сертификатов для Hysteria2"
  echo
  echo "Xray на всех нодах сможет использовать одинаковые пути:"
  echo "  $HY2_CONTAINER_CERT_ROOT/hy2/fullchain.pem"
  echo "  $HY2_CONTAINER_CERT_ROOT/hy2/privkey.pem"
  echo

  read -p "Введите домен, для которого уже выпущен Let's Encrypt сертификат: " HY2_DOMAIN

  if [ -z "$HY2_DOMAIN" ]; then
    echo "❌ Домен не указан. Настройка Hysteria2 пропущена."
    return 0
  fi

  local LE_CERT_DIR="/etc/letsencrypt/live/$HY2_DOMAIN"
  local LE_FULLCHAIN="$LE_CERT_DIR/fullchain.pem"
  local LE_PRIVKEY="$LE_CERT_DIR/privkey.pem"

  if [ ! -f "$LE_FULLCHAIN" ] || [ ! -f "$LE_PRIVKEY" ]; then
    echo "❌ Сертификат для $HY2_DOMAIN не найден."
    echo "Ожидались файлы:"
    echo "  $LE_FULLCHAIN"
    echo "  $LE_PRIVKEY"
    echo
    echo "Сначала убедитесь, что selfsteal/Certbot успешно выпустил сертификат."
    echo "Настройка Hysteria2 пропущена."
    return 0
  fi

  echo "📁 Создаем универсальную директорию сертификатов..."
  mkdir -p "$HY2_CERT_DIR"

  echo "📄 Копируем текущий сертификат..."
  install -m 0644 -T "$LE_FULLCHAIN" "$HY2_CERT_DIR/fullchain.pem"
  install -m 0600 -T "$LE_PRIVKEY" "$HY2_CERT_DIR/privkey.pem"

  echo "📝 Добавляем сертификаты в Remnanode через Docker volume..."
  ensure_compose_volume "$HY2_VOLUME"

  echo "🔄 Применяем обновленный docker-compose.yml..."
  cd "$TARGET_DIR"
  docker compose up -d

  echo "🛠️ Создаем скрипт синхронизации сертификата..."
  cat > "$HY2_SYNC_SCRIPT" << EOF
#!/bin/bash
set -e

DOMAIN="$HY2_DOMAIN"
SOURCE_DIR="/etc/letsencrypt/live/\$DOMAIN"
DEST_DIR="$HY2_CERT_DIR"

if [ ! -f "\$SOURCE_DIR/fullchain.pem" ] || [ ! -f "\$SOURCE_DIR/privkey.pem" ]; then
  echo "Hysteria2 certificate sync: certificate files for \$DOMAIN not found." >&2
  exit 1
fi

mkdir -p "\$DEST_DIR"

install -m 0644 -T "\$SOURCE_DIR/fullchain.pem" "\$DEST_DIR/fullchain.pem"
install -m 0600 -T "\$SOURCE_DIR/privkey.pem" "\$DEST_DIR/privkey.pem"

if docker ps --format '{{.Names}}' | grep -qx 'remnanode'; then
  docker restart remnanode >/dev/null
fi
EOF
  chmod 0755 "$HY2_SYNC_SCRIPT"

  echo "♻️ Настраиваем автоматическую синхронизацию после certbot renew..."
  mkdir -p "$(dirname "$HY2_DEPLOY_HOOK")"
  cat > "$HY2_DEPLOY_HOOK" << EOF
#!/bin/bash
set -e
"$HY2_SYNC_SCRIPT"
EOF
  chmod 0755 "$HY2_DEPLOY_HOOK"

  echo
  echo "✅ Сертификаты Hysteria2 настроены."
  echo
  echo "Используйте в общем Xray-профиле:"
  echo
  echo '"certificates": ['
  echo '  {'
  echo '    "keyFile": "/etc/xray-certs/hy2/privkey.pem",'
  echo '    "certificateFile": "/etc/xray-certs/hy2/fullchain.pem"'
  echo '  }'
  echo ']'
  echo
  echo "Локальные файлы ноды:"
  echo "  $HY2_CERT_DIR/fullchain.pem"
  echo "  $HY2_CERT_DIR/privkey.pem"
  echo
  echo "После успешного certbot renew сертификаты будут автоматически"
  echo "скопированы сюда заново, после чего контейнер Remnanode перезапустится."
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
