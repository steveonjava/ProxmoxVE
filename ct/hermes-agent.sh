#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/steveonjava/ProxmoxVE/main/misc/build.func)

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Stephen Chin (steveonjava)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://hermes-agent.nousresearch.com/

APP="Hermes Agent"
var_tags="${var_tags:-ai;automation;agent}"
var_cpu="${var_cpu:-2}"
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

  msg_info "Updating ${APP}"
  $STD env \
    HOME=/home/hermes \
    HERMES_HOME=/home/hermes/.hermes \
    PLAYWRIGHT_BROWSERS_PATH=/home/hermes/.cache/ms-playwright \
    /home/hermes/.local/bin/hermes update
  chown -R hermes:hermes /home/hermes/.hermes /home/hermes/.local
  if [[ -d /home/hermes/.cache ]]; then
    chown -R hermes:hermes /home/hermes/.cache
  fi
  msg_ok "Updated ${APP}"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Connect via SSH and configure your LLM provider:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}ssh hermes@${IP}${CL}"
echo -e "${TAB}${GATEWAY}${BGN}hermes setup${CL}"
