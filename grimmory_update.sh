#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/grimmory-tools/grimmory
# Modified by dalenjohnson. Forked by databoy2k for Grimmory 3.x

APP="Grimmory"
var_tags="${var_tags:-books;library}"
var_cpu="${var_cpu:-3}"
var_ram="${var_ram:-3072}"
var_disk="${var_disk:-7}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function setup_kepubify() {
  local OLD_PATH="/opt/booklore_storage/data/tools/kepubify"
  local NEW_PATH="/usr/local/bin/kepubify"
  local ARCH
  local URL

  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64) URL="https://github.com/pgaskin/kepubify/releases/latest/download/kepubify-linux-64bit" ;;
    arm64) URL="https://github.com/pgaskin/kepubify/releases/latest/download/kepubify-linux-arm64" ;;
    *)
      msg_error "Unsupported architecture: $ARCH"
      return 1
      ;;
  esac

  mkdir -p /usr/local/bin

  # Fail clearly if a previous bad install created a directory here
  if [[ -d "$NEW_PATH" ]]; then
    msg_error "Invalid kepubify install detected at $NEW_PATH. It is a directory, not a binary."
    return 1
  fi

  # Migrate from old location if present and valid
  if [[ -f "$OLD_PATH" && -x "$OLD_PATH" && ! -f "$NEW_PATH" ]]; then
    if "$OLD_PATH" --help >/dev/null 2>&1; then
      msg_info "Migrating kepubify to /usr/local/bin"
      mv "$OLD_PATH" "$NEW_PATH"
      chmod 0755 "$NEW_PATH"
    else
      msg_warn "Skipping migration: invalid kepubify binary at $OLD_PATH"
    fi
  fi

  # If not installed → ask user
  if [[ -f "$NEW_PATH" ]]; then
    msg_info "Updating Kepubify"
  else
    if command -v whiptail >/dev/null 2>&1; then
      if ! whiptail \
        --backtitle "Proxmox VE Helper Scripts" \
        --title "KEPUBIFY" \
        --yesno "Kepubify not found.\n\nInstall it for Kobo Sync support?" 10 60; then
        msg_info "Skipping Kepubify"
        return 0
      fi
    else
      read -r -p "Kepubify not found. Install it? [y/N]: " reply
      [[ "$reply" =~ ^[Yy]$ ]] || return 0
    fi
    msg_info "Installing Kepubify"
  fi

  # Download latest
  if ! wget -q "$URL" -O /tmp/kepubify; then
    msg_error "Failed to download Kepubify"
    return 1
  fi

  # Install
  if ! install -m 0755 -T /tmp/kepubify "$NEW_PATH"; then
    rm -f /tmp/kepubify
    msg_error "Failed to install Kepubify"
    return 1
  fi

  rm -f /tmp/kepubify

  if [[ ! -f "$NEW_PATH" || ! -x "$NEW_PATH" ]]; then
    msg_error "Kepubify install verification failed: binary missing or not executable"
    return 1
  fi

  if ! command -v kepubify >/dev/null 2>&1; then
    msg_error "Kepubify install verification failed: not found in PATH"
    return 1
  fi

  msg_ok "Kepubify ready"
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  # Installation check:
  if [[ ! -d /opt/booklore && ! -d /opt/grimmory ]]; then
    msg_error "No BookLore or ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "grimmory" "grimmory-tools/grimmory"; then
    JAVA_VERSION="25"
    setup_java
    NODE_VERSION="22"
    setup_nodejs
    setup_mariadb
    setup_yq
    ensure_dependencies ffmpeg libarchive13
    setup_kepubify
    
    # Confirm libarchive symlink
    if [[ ! -L /usr/lib/libarchive.so ]]; then
      ln -s /lib/x86_64-linux-gnu/libarchive.so /usr/lib/
    fi

    # Service stop:
    msg_info "Stopping Service"
    if [[ -d /opt/grimmory ]]; then
      systemctl stop grimmory || true
    else
      systemctl stop booklore || true
    fi
    msg_ok "Stopped Service"

    # Env var migration:
    if grep -qE "^BOOKLORE_(DATA_PATH|BOOKDROP_PATH|BOOKS_PATH|PORT)=" /opt/booklore_storage/.env 2>/dev/null; then
      msg_info "Migrating old environment variables"
      sed -i 's/^BOOKLORE_DATA_PATH=/APP_PATH_CONFIG=/g' /opt/booklore_storage/.env
      sed -i 's/^BOOKLORE_BOOKDROP_PATH=/APP_BOOKDROP_FOLDER=/g' /opt/booklore_storage/.env
      sed -i '/^BOOKLORE_BOOKS_PATH=/d' /opt/booklore_storage/.env
      sed -i '/^BOOKLORE_PORT=/d' /opt/booklore_storage/.env
      msg_ok "Migrated old environment variables"
    fi

    # Backup:
    msg_info "Backing up old installation"
    rm -rf /opt/grimmory_bak /opt/booklore_bak
    if [[ -d /opt/booklore ]]; then
      mv /opt/booklore /opt/booklore_bak
    elif [[ -d /opt/grimmory ]]; then
      cp -a /opt/grimmory /opt/grimmory_bak
    fi
    msg_ok "Backed up old installation"

    # Wipe existing grimmory dir before fresh deploy
    rm -rf /opt/grimmory
    fetch_and_deploy_gh_release "grimmory" "grimmory-tools/grimmory" "tarball"

    # Frontend build:
    msg_info "Building Frontend"
    cd /opt/grimmory/frontend || exit 1
    $STD npm install --force
    $STD npm run build --configuration=production
    msg_ok "Built Frontend"

    # Backend build:
    msg_info "Building Backend"
    cd /opt/grimmory/backend || exit 1
    APP_VERSION=$(get_latest_github_release "grimmory-tools/grimmory")
    $STD yq eval ".app.version = \"${APP_VERSION}\"" -i src/main/resources/application.yaml
    $STD ./gradlew clean bootJar -PfrontendDistDir=/opt/grimmory/frontend/dist/grimmory/browser -x test --no-daemon

    mkdir -p /opt/grimmory/dist
    JAR_PATH=$(find /opt/grimmory/backend/build/libs -maxdepth 1 -type f -name "*.jar" ! -name "*plain*" | head -n1)
    if [[ -z "$JAR_PATH" ]]; then
      msg_error "Backend JAR not found"
      exit
    fi
    cp "$JAR_PATH" /opt/grimmory/dist/app.jar
    msg_ok "Built Backend"

    # Nginx removal:
    if systemctl is-active --quiet nginx 2>/dev/null; then
      msg_info "Removing Nginx (no longer needed)"
      systemctl disable --now nginx >/dev/null 2>&1 || true
      $STD apt-get purge -y nginx nginx-common
      msg_ok "Removed Nginx"
    fi

    # SERVER_PORT injection:
    if ! grep -q "^SERVER_PORT=" /opt/booklore_storage/.env 2>/dev/null; then
      echo "SERVER_PORT=6060" >> /opt/booklore_storage/.env
    fi

    if [[ -f /etc/systemd/system/booklore.service && ! -f /etc/systemd/system/grimmory.service ]]; then
      mv /etc/systemd/system/booklore.service /etc/systemd/system/grimmory.service
    fi

    # Service file migration:
    if [[ ! -f /etc/systemd/system/grimmory.service ]]; then
      msg_error "grimmory.service not found"
      exit
    fi

    sed -i 's|WorkingDirectory=.*|WorkingDirectory=/opt/grimmory/dist|' /etc/systemd/system/grimmory.service
    sed -i 's|ExecStart=.*|ExecStart=/usr/bin/java --enable-preview -XX:+UseG1GC -XX:+UseStringDeduplication -XX:+UseCompactObjectHeaders -XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError -jar /opt/grimmory/dist/app.jar|' /etc/systemd/system/grimmory.service
    systemctl daemon-reload
    systemctl disable --now booklore.service >/dev/null 2>&1 || true

    # Start + cleanup:
    msg_info "Starting Service"
    systemctl enable --now grimmory.service

    sleep 2
    if ! systemctl is-active --quiet grimmory.service; then
      msg_error "Grimmory service failed to start. Backups were retained."
      exit 1
    fi

    rm -rf /opt/grimmory_bak /opt/booklore_bak
    msg_ok "Started Service"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description
update_script "$@"

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:6060${CL}"
