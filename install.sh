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
SHOULD_INSTALL=true

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
