#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts
# Author: Stephen Chin
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/ProtonMail/proton-bridge
# Description: Installs Proton Mail Bridge, creates systemd services, and exposes IMAP/SMTP via socat.

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing dependencies"
$STD apt-get install -y \
  ca-certificates \
  gpg \
  jq \
  libsecret-1-0 \
  pass \
  socat \
  sudo
msg_ok "Installed dependencies"

# Create a dedicated user for the bridge
msg_info "Creating service user"
if ! id -u protonbridge >/dev/null 2>&1; then
  useradd -r -m -d /home/protonbridge -s /usr/sbin/nologin protonbridge
fi
install -d -m 0750 -o protonbridge -g protonbridge /home/protonbridge
msg_ok "Created service user"

msg_info "Installing Proton Mail Bridge (GitHub release .deb via helper)"
fetch_and_deploy_gh_release "protonmail-bridge" "ProtonMail/proton-bridge" "binary"
msg_ok "Installed Proton Mail Bridge"

# Record installed version
INSTALLED_VER="$(/usr/bin/protonmail-bridge --version 2>/dev/null | head -n 1 | tr -d '\r' || true)"
echo "${INSTALLED_VER}" > /opt/.protonmailbridge-version

# Service: Proton Mail Bridge CLI, kept alive with FIFO trick like the Docker entrypoint
msg_info "Creating systemd services"

cat > /etc/systemd/system/protonmail-bridge.service <<'EOF'
[Unit]
Description=Proton Mail Bridge (Headless CLI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=protonbridge
Group=protonbridge
WorkingDirectory=/home/protonbridge
Environment=HOME=/home/protonbridge
RuntimeDirectory=protonmail-bridge
RuntimeDirectoryMode=0750
ExecStart=/bin/bash -lc 'rm -f /run/protonmail-bridge/faketty; mkfifo /run/protonmail-bridge/faketty; cat /run/protonmail-bridge/faketty | /usr/bin/protonmail-bridge -c'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Forward SMTP: LAN 587 -> Bridge localhost 1025
cat > /etc/systemd/system/protonmail-bridge-smtp-forward.service <<'EOF'
[Unit]
Description=Proton Mail Bridge SMTP Forward (587 -> 127.0.0.1:1025)
After=protonmail-bridge.service
Wants=protonmail-bridge.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP4-LISTEN:587,fork,reuseaddr TCP4:127.0.0.1:1025
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# Forward IMAP: LAN 143 -> Bridge localhost 1143
cat > /etc/systemd/system/protonmail-bridge-imap-forward.service <<'EOF'
[Unit]
Description=Proton Mail Bridge IMAP Forward (143 -> 127.0.0.1:1143)
After=protonmail-bridge.service
Wants=protonmail-bridge.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP4-LISTEN:143,fork,reuseaddr TCP4:127.0.0.1:1143
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# In-container updater at /usr/bin/update (Helper-Scripts convention)
cat > /usr/bin/update <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

systemctl stop protonmail-bridge-imap-forward.service protonmail-bridge-smtp-forward.service protonmail-bridge.service || true

fetch_and_deploy_gh_release "protonmail-bridge" "ProtonMail/proton-bridge" "binary"

systemctl daemon-reload
systemctl start protonmail-bridge.service protonmail-bridge-imap-forward.service protonmail-bridge-smtp-forward.service

/usr/bin/protonmail-bridge --version 2>/dev/null | head -n 1 > /opt/.protonmailbridge-version || true
echo "Proton Mail Bridge updated successfully."
EOF
chmod +x /usr/bin/update

cat > /usr/local/bin/protonmailbridge-init <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BRIDGE_USER="protonbridge"
MARKER="/home/${BRIDGE_USER}/.protonmailbridge-initialized"

if [[ -f "$MARKER" ]]; then
  echo "Already initialized. To start services:"
  echo "  systemctl enable --now protonmail-bridge.service protonmail-bridge-imap-forward.service protonmail-bridge-smtp-forward.service"
  exit 0
fi

echo "Initializing pass keychain for ${BRIDGE_USER} (required by Proton Mail Bridge on Linux)."

# 1) Create a no-passphrase GPG key for pass (headless-friendly)
sudo -u "$BRIDGE_USER" gpg --batch --passphrase '' --quick-gen-key 'ProtonMail Bridge' default default never

# 2) Find fingerprint and init pass store
FPR="$(sudo -u "$BRIDGE_USER" gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"
if [[ -z "${FPR}" ]]; then
  echo "Failed to detect GPG key fingerprint for ${BRIDGE_USER}." >&2
  exit 1
fi
sudo -u "$BRIDGE_USER" pass init "$FPR"

echo
echo "Starting Proton Mail Bridge CLI for one-time login. Run:"
echo "  login"
echo "  info"
echo "  exit"
echo
sudo -u "$BRIDGE_USER" protonmail-bridge -c

# Mark initialized and start services
touch "$MARKER"
chown "${BRIDGE_USER}:${BRIDGE_USER}" "$MARKER"

systemctl daemon-reload
systemctl enable --now protonmail-bridge.service protonmail-bridge-imap-forward.service protonmail-bridge-smtp-forward.service

echo "Initialization complete. Services enabled and started."
EOF
chmod +x /usr/local/bin/protonmailbridge-init

systemctl daemon-reload
systemctl disable --now protonmail-bridge.service protonmail-bridge-smtp-forward.service protonmail-bridge-imap-forward.service 2>/dev/null || true

msg_ok "Created and temporarily disabled services"

motd_ssh
customize

msg_info "Cleanup"
cleanup_lxc
msg_ok "Cleanup complete"
