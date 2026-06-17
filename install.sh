#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: run as root"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

TARGET_DIR="/opt/remnanode"

if [ ! -f "$TARGET_DIR/docker-compose.yml" ]; then
    mkdir -p "$TARGET_DIR"
    cd "$TARGET_DIR"

    read -p "Enter SECRET_KEY: " SECRET_KEY

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
else
    cd "$TARGET_DIR"
fi

docker compose up -d
