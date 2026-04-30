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

msg_info "Updating OS"
$STD apt-get update
$STD apt-get -y upgrade
msg_ok "Updated OS"

msg_info "Installing dependencies"
$STD apt-get install -y git curl ca-certificates sudo
msg_ok "Installed dependencies"

msg_info "Creating hermes user"
useradd -m -s /bin/bash hermes
echo "hermes ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/hermes
chmod 440 /etc/sudoers.d/hermes
msg_ok "Created hermes user"

msg_info "Installing Hermes Agent"
sudo -u hermes bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup'
sudo -u hermes /home/hermes/.local/bin/hermes --version
msg_ok "Installed Hermes Agent"

msg_info "Configuring system service"
cat >/etc/systemd/system/hermes-agent.service <<'EOF'
[Unit]
Description=Hermes Agent Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hermes
Group=hermes
WorkingDirectory=/home/hermes
ExecStart=/home/hermes/.local/bin/hermes gateway
Restart=on-failure
RestartSec=5
Environment=HOME=/home/hermes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hermes-agent
msg_ok "Configured system service"

msg_info "Configuring SSH"
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh
msg_ok "Configured SSH"

msg_info "Storing version"
APPLICATION="hermes-agent"
sudo -u hermes bash -c '/home/hermes/.local/bin/hermes --version' | head -1 >/opt/${APPLICATION}_version.txt
msg_ok "Stored version"

motd_ssh
customize
cleanup_lxc
