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

  if [[ ! -x /home/hermes/.local/bin/hermes ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Stopping Service"
  systemctl stop hermes-gateway
  msg_ok "Stopped Service"

  msg_info "Updating ${APP}"
  git config --system --add safe.directory /home/hermes/.hermes/hermes-agent 2>/dev/null || true
  $STD env \
    HOME=/home/hermes \
    HERMES_HOME=/home/hermes/.hermes \
    /home/hermes/.local/bin/hermes update
  chown -R hermes:hermes /home/hermes/.hermes /home/hermes/.local
  if [[ -d /home/hermes/.cache ]]; then
    chown -R hermes:hermes /home/hermes/.cache
  fi
  msg_ok "Updated ${APP}"

  msg_info "Starting Service"
  systemctl start hermes-gateway
  msg_ok "Started Service"
  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Connect via SSH and configure your LLM provider:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}ssh hermes@${IP}${CL}"
echo -e "${TAB}${BGN}hermes setup${CL}"
echo -e "${INFO}${YW} API Server (OpenAI-compatible):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8642${CL}"
echo -e "${INFO}${YW} API Key:${CL}"
echo -e "${TAB}${BGN}cat /home/hermes/.hermes/.env${CL}"
echo -e "${INFO}${YW} Web Dashboard (via SSH tunnel):${CL}"
echo -e "${TAB}${BGN}ssh -L 9119:localhost:9119 hermes@${IP}${CL}"
echo -e "${TAB}${BGN}Then open: http://localhost:9119${CL}"
