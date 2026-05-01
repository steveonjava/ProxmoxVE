#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Stephen Chin (steveonjava)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://hermes-agent.nousresearch.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6

catch_errors
setting_up_container
network_check
update_os

msg_info "Creating Service User"
if ! id -u hermes >/dev/null 2>&1; then
	useradd -m -s /bin/bash hermes
fi
msg_ok "Created Service User"

msg_info "Installing Hermes Agent"
env \
	HOME=/home/hermes \
	PATH=/home/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HERMES_HOME=/home/hermes/.hermes \
	PLAYWRIGHT_BROWSERS_PATH=/home/hermes/.cache/ms-playwright \
	DEBIAN_FRONTEND=noninteractive \
	NEEDRESTART_MODE=a \
	bash -lc 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup --hermes-home /home/hermes/.hermes --dir /home/hermes/.hermes/hermes-agent'

if [[ ! -x /home/hermes/.local/bin/hermes ]]; then
	msg_error "Hermes binary not found after installation"
	exit 1
fi

chown -R hermes:hermes /home/hermes/.hermes /home/hermes/.local
if [[ -d /home/hermes/.cache ]]; then
	chown -R hermes:hermes /home/hermes/.cache
fi
runuser -u hermes -- env HOME=/home/hermes HERMES_HOME=/home/hermes/.hermes /home/hermes/.local/bin/hermes --version
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
Environment="HERMES_HOME=/home/hermes/.hermes"
Environment="HOME=/home/hermes"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now hermes-gateway
msg_ok "Created Service"

msg_info "Creating Hermes Shim"
cat <<'EOF' >/usr/bin/hermes
#!/bin/bash
cd /home/hermes
exec runuser -u hermes -- /home/hermes/.local/bin/hermes "$@"
EOF
chmod +x /usr/bin/hermes
msg_ok "Created Hermes Shim"

msg_info "Storing Version"
runuser -u hermes -- env HOME=/home/hermes HERMES_HOME=/home/hermes/.hermes /home/hermes/.local/bin/hermes --version | head -1 >/opt/hermes-agent_version.txt
msg_ok "Stored Version"

motd_ssh
customize
cleanup_lxc
