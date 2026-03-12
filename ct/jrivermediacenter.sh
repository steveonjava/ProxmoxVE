#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Stephen Chin (steveonjava)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://www.jriver.com/

source <(curl -fsSL https://raw.githubusercontent.com/steveonjava/ProxmoxVE/main/misc/build.func)

APP="JRiver Media Center"
var_tags="${var_tags:-media}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x /usr/bin/mediacenter35 ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Updating installJRMC"
  curl -fsSL https://git.bryanroessler.com/bryan/installJRMC/raw/branch/master/installJRMC \
    -o /usr/local/bin/installJRMC
  chmod +x /usr/local/bin/installJRMC
  msg_ok "Updated installJRMC"

  msg_info "Updating JRiver Media Center"
  $STD runuser -l jriver -- /usr/local/bin/installJRMC \
    --install=repo \
    --yes \
    --no-update
  msg_ok "Updated JRiver Media Center"

  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Open the browser setup page:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}https://${IP}:5800/setup/${CL}"
echo -e "${INFO}${YW} Default mode is Media Server; launch the interactive UI from the Dashboard when needed.${CL}"
echo -e "${INFO}${YW} Secure native VNC can be enabled from the Dashboard on port ${BGN}5902${CL}${YW} for compatible TigerVNC desktop clients, uses the same Dashboard credentials, and supports client-driven desktop resize while UI mode is active.${CL}"
echo -e "${INFO}${YW} Import .mjr license files with ${BGN}jrmc-activate /path/to/file.mjr${CL}${YW}.${CL}"
echo -e "${INFO}${YW} A JRiver Media Center license is required: https://www.jriver.com/${CL}"
