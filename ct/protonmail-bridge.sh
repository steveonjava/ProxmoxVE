#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts
# Author: Stephen Chin
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/ProtonMail/proton-bridge
# Description: Debian LXC that runs Proton Mail Bridge headless and exposes IMAP/SMTP to the LAN via socat.

source <(curl -fsSL https://raw.githubusercontent.com/steveonjava/ProxmoxVE/refs/heads/main/misc/build.func)

APP="ProtonMail Bridge"
var_tags="${var_tags:-mail;proton}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-512}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
echo "DEBUG: APP=$APP NSAPP=$NSAPP var_install=$var_install"
echo "DEBUG: installer URL=https://raw.githubusercontent.com/steveonjava/ProxmoxVE/refs/heads/main/install/${var_install}.sh"
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x /usr/bin/protonmail-bridge ]]; then
    msg_error "No ${APP} installation found."
    exit 1
  fi

  # Delegate update logic to the in-container updater placed by the install script
  msg_info "Running in-container updater"
  if [[ -x /usr/bin/update ]]; then
    /usr/bin/update
    msg_ok "Update complete"
  else
    msg_error "Updater not found at /usr/bin/update"
    exit 1
  fi

  exit
}

start
build_container
description

msg_ok "Completed successfully!"
echo -e "${CREATING}${GN}${APP} has been successfully installed!${CL}"
echo -e "${INFO}${YW}Bridge listens on localhost (container):${CL}"
echo -e "${TAB}${YW}IMAP 127.0.0.1:1143${CL}"
echo -e "${TAB}${YW}SMTP 127.0.0.1:1025${CL}"
echo -e "${INFO}${YW}LAN-accessible forwarded ports (container IP ${IP}):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}IMAP  ${IP}:143${CL}"
echo -e "${TAB}${GATEWAY}${BGN}SMTP  ${IP}:587${CL}"
echo -e "${INFO}${YW}Initialize the account inside the container:${CL}"
echo -e "${TAB}${YW}sudo -u protonbridge protonmail-bridge -c${CL}"
echo -e "${INFO}${YW}Then run 'login' in the CLI, and 'info' to retrieve client credentials.${CL}"
