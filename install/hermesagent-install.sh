#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/steveonjava/ProxmoxVE/raw/main/LICENSE
# Source: https://hermes-agent.nousresearch.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6

# In dev trace mode, shared helpers set PS4 to reference BASH_SOURCE.
# Under bash -c with nounset, BASH_SOURCE can be unset and abort execution.
if [[ "${DEV_MODE_TRACE:-false}" == "true" ]]; then
	set +x
fi

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
sudo -u hermes bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
sudo -u hermes bash -c 'source ~/.bashrc && hermes --version'
msg_ok "Installed Hermes Agent"

msg_info "Configuring systemd user service"
loginctl enable-linger hermes
mkdir -p /home/hermes/.config/systemd/user

cat >/home/hermes/.config/systemd/user/hermes-agent.service <<'EOF'
[Unit]
Description=Hermes Agent Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/home/hermes/.local/bin/hermes gateway
Restart=on-failure
RestartSec=5
Environment=HOME=/home/hermes

[Install]
WantedBy=default.target
EOF

chown -R hermes:hermes /home/hermes/.config/systemd
chmod 700 /home/hermes/.config/systemd/user
chmod 644 /home/hermes/.config/systemd/user/hermes-agent.service

sudo -u hermes bash -c 'XDG_RUNTIME_DIR=/run/user/$(id -u hermes) systemctl --user daemon-reload'
sudo -u hermes bash -c 'XDG_RUNTIME_DIR=/run/user/$(id -u hermes) systemctl --user enable hermes-agent'
msg_ok "Configured systemd user service"

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
