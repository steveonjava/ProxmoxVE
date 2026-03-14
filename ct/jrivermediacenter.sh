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
echo -e "${INFO}${YW} The Dashboard now exposes three primary modes: ${BGN}Media Server${CL}${YW}, ${BGN}VNC${CL}${YW}, and ${BGN}RDP${CL}${YW}. Choosing one mode cleanly tears down the others first.${CL}"
echo -e "${INFO}${YW} VNC mode enables both browser noVNC and direct VNC on port ${BGN}5902${CL}${YW} together against the same JRMC session using the same Dashboard credentials.${CL}"
echo -e "${INFO}${YW} RDP mode listens on port ${BGN}3389${CL}${YW} for Remmina using the same Dashboard username and password.${CL}"
echo -e "${INFO}${YW} Dashboard includes JRMC UI scale presets from ${BGN}100%${CL}${YW} to ${BGN}200%${CL}${YW}. VNC mode uses a larger server framebuffer as scale increases, while RDP maps the preset into JRiver's own internal Standard View size before launch.${CL}"
echo -e "${INFO}${YW} Import .mjr license files with ${BGN}jrmc-activate /path/to/file.mjr${CL}${YW}.${CL}"
echo -e "${INFO}${YW} A JRiver Media Center license is required: https://www.jriver.com/${CL}"
