#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Stephen Chin (steveonjava)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://www.jriver.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  dbus-x11 \
  x11-xserver-utils \
  tigervnc-standalone-server \
  xauth \
  sudo
msg_ok "Installed Dependencies"

msg_info "Creating Service User"
useradd -m -d /home/jriver -s /bin/bash jriver
echo "jriver ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/jriver
chmod 0440 /etc/sudoers.d/jriver
msg_ok "Created Service User"

msg_info "Preparing VNC directories"
# Pre-create tigervnc config dirs so the vncserver wrapper's migration
# check never fires (it always fails inside LXC containers).
install -d -m 700 -o jriver -g jriver /home/jriver/.vnc
install -d -m 700 -o jriver -g jriver /home/jriver/.config
install -d -m 700 -o jriver -g jriver /home/jriver/.config/tigervnc
msg_ok "Prepared VNC directories"

msg_info "Downloading installJRMC"
curl -fsSL https://git.bryanroessler.com/bryan/installJRMC/raw/branch/master/installJRMC \
  -o /usr/local/bin/installJRMC
chmod +x /usr/local/bin/installJRMC
msg_ok "Downloaded installJRMC"

msg_info "Installing JRiver Media Center 35 (this may take several minutes)"
# Install repo/packages only — we manage VNC ourselves to avoid the
# vncserver Perl wrapper's broken .vnc migration inside LXC.
$STD runuser -l jriver -- /usr/local/bin/installJRMC \
  --install=repo \
  --yes \
  --no-update
msg_ok "Installed JRiver Media Center 35"

msg_info "Configuring VNC Service"
VNC_DISPLAY=1
VNC_PORT=5901

# Create a launcher that calls Xtigervnc directly (bypasses vncserver wrapper).
cat <<'LAUNCHER' >/usr/local/bin/jriver-vnc-start
#!/bin/bash
set -e
export HOME=/home/jriver
export USER=jriver
export DISPLAY=:1

# Ensure .Xauthority exists
touch "$HOME/.Xauthority"
xauth generate "$DISPLAY" . trusted 2>/dev/null || true

# Start Xtigervnc directly — no vncserver Perl wrapper
/usr/bin/Xtigervnc "$DISPLAY" \
  -geometry 1440x900 \
  -rfbport 5901 \
  -AlwaysShared \
  -NeverShared=0 \
  -SecurityTypes None \
  -localhost 0 \
  -desktop "JRiver Media Center" \
  -auth "$HOME/.Xauthority" &
XVNC_PID=$!

# Wait for the X display to become ready (up to 15s)
for _i in $(seq 1 30); do
  xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
  sleep 0.5
done

# Launch JRiver Media Center on the VNC display
/usr/bin/mediacenter35 &

# Stay alive while Xtigervnc is running
wait $XVNC_PID
LAUNCHER
chmod +x /usr/local/bin/jriver-vnc-start

# Systemd unit — Type=simple, calls Xtigervnc directly via the launcher.
cat <<UNIT >/etc/systemd/system/jriver-xvnc@.service
[Unit]
Description=JRiver Media Center VNC (display :${VNC_DISPLAY})
After=network.target

[Service]
Type=simple
User=%i
ExecStartPre=-/bin/sh -c 'rm -f /tmp/.X${VNC_DISPLAY}-lock /tmp/.X11-unix/X${VNC_DISPLAY}'
ExecStart=/usr/local/bin/jriver-vnc-start
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# Clean any stale X locks
rm -f /tmp/.X*-lock /tmp/.X11-unix/X*

systemctl daemon-reload
systemctl enable --now jriver-xvnc@jriver.service
msg_ok "VNC listening on port ${VNC_PORT} (display :${VNC_DISPLAY})"

msg_info "Creating Helper Commands"
cat <<'EOF' >/usr/local/bin/jriver-configure
#!/usr/bin/env bash
set -euo pipefail

JRIVER_USER="jriver"
JRIVER_HOME="/home/${JRIVER_USER}"

echo "JRiver Media Center Configuration"
echo "==================================="
echo
echo "Current VNC display:  :1 (port 5901, LAN accessible)"
echo "Service user:         ${JRIVER_USER}"
echo "Home directory:       ${JRIVER_HOME}"
echo

PS3="Select an option: "
select opt in \
  "Set VNC password" \
  "Remove VNC password (no auth)" \
  "Restart VNC + Media Center" \
  "Stop VNC + Media Center" \
  "Start VNC + Media Center" \
  "Update JRiver Media Center" \
  "Exit"; do
  case $opt in
  "Set VNC password")
    read -r -s -p "Enter new VNC password: " pass
    echo
    install -d -m 0700 -o "${JRIVER_USER}" -g "${JRIVER_USER}" "${JRIVER_HOME}/.vnc"
    echo "$pass" | runuser -u "${JRIVER_USER}" -- vncpasswd -f >"${JRIVER_HOME}/.vnc/jrmc_passwd"
    chown "${JRIVER_USER}:${JRIVER_USER}" "${JRIVER_HOME}/.vnc/jrmc_passwd"
    chmod 0600 "${JRIVER_HOME}/.vnc/jrmc_passwd"
    echo "VNC password set. Restart the VNC service to apply."
    ;;
  "Remove VNC password (no auth)")
    rm -f "${JRIVER_HOME}/.vnc/jrmc_passwd"
    echo "VNC password removed. Restart the VNC service to apply."
    ;;
  "Restart VNC + Media Center")
    systemctl restart "jriver-xvnc@${JRIVER_USER}.service"
    echo "Restarted."
    ;;
  "Stop VNC + Media Center")
    systemctl stop "jriver-xvnc@${JRIVER_USER}.service"
    echo "Stopped."
    ;;
  "Start VNC + Media Center")
    systemctl start "jriver-xvnc@${JRIVER_USER}.service"
    echo "Started."
    ;;
  "Update JRiver Media Center")
    runuser -l "${JRIVER_USER}" -- /usr/local/bin/installJRMC \
      --install=repo \
      --yes
    echo "Update complete."
    ;;
  "Exit")
    break
    ;;
  *) echo "Invalid option" ;;
  esac
  echo
done
EOF
chmod +x /usr/local/bin/jriver-configure
ln -sf /usr/local/bin/jriver-configure /usr/bin/jriver-configure
msg_ok "Created Helper Commands"

motd_ssh
customize
cleanup_lxc
