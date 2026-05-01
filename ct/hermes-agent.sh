#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/misc/build.func)

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

  if [[ ! -d /home/hermes/.hermes/hermes-agent ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating ${APP}"
  $STD runuser -u hermes -- env HOME=/home/hermes HERMES_HOME=/home/hermes/.hermes /home/hermes/.local/bin/hermes update
  $STD runuser -u hermes -- env HOME=/home/hermes HERMES_HOME=/home/hermes/.hermes /home/hermes/.local/bin/hermes config migrate
  msg_ok "Updated ${APP}"
  msg_ok "Updated successfully!"
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
