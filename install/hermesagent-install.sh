#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/steveonjava/ProxmoxVE/raw/main/LICENSE
# Source: https://hermes-agent.nousresearch.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6

catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y git curl ca-certificates sudo
msg_ok "Installed Dependencies"

msg_info "Creating Service User"
useradd -m -s /bin/bash hermes
echo "hermes ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/hermes
chmod 0440 /etc/sudoers.d/hermes
msg_ok "Created Service User"

msg_info "Installing Hermes Agent"
sudo -u hermes bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup'
sudo -u hermes /home/hermes/.local/bin/hermes --version
msg_ok "Installed Hermes Agent"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/hermes-gateway.service
[Unit]
Description=Hermes Agent Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hermes
Group=hermes
WorkingDirectory=/home/hermes
ExecStart=/home/hermes/.local/bin/hermes gateway run --replace
Restart=on-failure
RestartSec=5
Environment=HOME=/home/hermes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now hermes-gateway
msg_ok "Created Service"

msg_info "Storing Version"
sudo -u hermes /home/hermes/.local/bin/hermes --version | head -1 >/opt/hermes-agent_version.txt
msg_ok "Stored Version"

motd_ssh
customize
cleanup_lxc
