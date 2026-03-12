#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Stephen Chin (steveonjava)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://www.jriver.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
APP="JRiver Media Center"
APP_ACRONYM="JRMC"
APP_USER="jriver"
APP_HOME="/home/${APP_USER}"
CONFIG_DIR="/etc/jrmc"
WEB_ROOT="/usr/share/jrmc-web"
CGI_BIN="/usr/lib/cgi-bin"
JRMC_DISPLAY=1
JRMC_VNC_PORT=5901
JRMC_NATIVE_VNC_PORT=5902
JRMC_NATIVE_RDP_PORT=3389
JRMC_WEBSOCKIFY_PORT=6080
JRMC_WEB_PORT=5800

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  apache2-utils \
  dbus-x11 \
  fcgiwrap \
  libpam-pwdfile \
  nginx \
  novnc \
  openbox \
  openssl \
  python3 \
  ssl-cert \
  tigervnc-scraping-server \
  tigervnc-standalone-server \
  websockify \
  x11-utils \
  x11-xserver-utils \
  xauth \
  xdotool \
  xorgxrdp \
  xrdp \
  sudo
msg_ok "Installed Dependencies"

msg_info "Creating Service User"
if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  useradd -m -d "${APP_HOME}" -s /bin/bash "${APP_USER}"
fi
echo "${APP_USER} ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/${APP_USER}
chmod 0440 /etc/sudoers.d/${APP_USER}
msg_ok "Created Service User"

msg_info "Preparing Runtime Directories"
install -d -m 700 -o "${APP_USER}" -g "${APP_USER}" \
  "${APP_HOME}/.vnc" \
  "${APP_HOME}/.config" \
  "${APP_HOME}/.config/tigervnc"
install -d -m 755 "${CONFIG_DIR}" "${WEB_ROOT}" "${WEB_ROOT}/setup" "${WEB_ROOT}/dashboard" "${CGI_BIN}"
make-ssl-cert generate-default-snakeoil --force-overwrite >/dev/null 2>&1 || true
cat <<EOF >/etc/default/jrmc
JRMC_USER="${APP_USER}"
JRMC_HOME="${APP_HOME}"
JRMC_DISPLAY="${JRMC_DISPLAY}"
JRMC_VNC_PORT="${JRMC_VNC_PORT}"
JRMC_NATIVE_VNC_PORT="${JRMC_NATIVE_VNC_PORT}"
JRMC_NATIVE_RDP_PORT="${JRMC_NATIVE_RDP_PORT}"
JRMC_WEBSOCKIFY_PORT="${JRMC_WEBSOCKIFY_PORT}"
JRMC_WEB_PORT="${JRMC_WEB_PORT}"
JRMC_WIDTH="1440"
JRMC_HEIGHT="900"
JRMC_WEB_HTPASSWD="/etc/nginx/jrmc.htpasswd"
JRMC_VNC_HTPASSWD="${CONFIG_DIR}/native-vnc.htpasswd"
JRMC_BOOTSTRAP_FILE="${CONFIG_DIR}/bootstrap-complete"
JRMC_NATIVE_VNC_ENABLED="0"
JRMC_NATIVE_RDP_ENABLED="0"
JRMC_NATIVE_RDP_USER="${APP_USER}"
JRMC_VNC_PAM_SERVICE="jrmc-vnc"
JRMC_NATIVE_VNC_SECURITY="TLSPlain"
JRMC_NATIVE_VNC_CERT="${CONFIG_DIR}/native-vnc-cert.pem"
JRMC_NATIVE_VNC_KEY="${CONFIG_DIR}/native-vnc-key.pem"
JRMC_NATIVE_VNC_PEM="${CONFIG_DIR}/native-vnc-server.pem"
JRMC_NATIVE_VNC_LOG="/tmp/jrmc-native-vnc.log"
EOF
chmod 0644 /etc/default/jrmc
msg_ok "Prepared Runtime Directories"

msg_info "Downloading installJRMC"
curl -fsSL https://git.bryanroessler.com/bryan/installJRMC/raw/branch/master/installJRMC \
  -o /usr/local/bin/installJRMC
chmod +x /usr/local/bin/installJRMC
msg_ok "Downloaded installJRMC"

msg_info "Installing ${APP} 35 (this may take several minutes)"
$STD runuser -l "${APP_USER}" -- /usr/local/bin/installJRMC \
  --install=repo \
  --yes \
  --no-update
msg_ok "Installed ${APP} 35"

msg_info "Configuring ${APP_ACRONYM} Runtime"
tmp_password=$(python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(32)))
PY
)
htpasswd -b -c -5 /etc/nginx/jrmc.htpasswd disabled "${tmp_password}" >/dev/null 2>&1
htpasswd -b -c -5 "${CONFIG_DIR}/native-vnc.htpasswd" disabled "${tmp_password}" >/dev/null 2>&1
chown root:www-data /etc/nginx/jrmc.htpasswd
chmod 0640 /etc/nginx/jrmc.htpasswd
chown "${APP_USER}:${APP_USER}" "${CONFIG_DIR}/native-vnc.htpasswd"
chmod 0600 "${CONFIG_DIR}/native-vnc.htpasswd"

cat <<'EOF' >/usr/local/bin/jrmc-vnc-start
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc
export HOME="${JRMC_HOME}"
export USER="${JRMC_USER}"
export DISPLAY=":${JRMC_DISPLAY}"

mkdir -p /tmp/.X11-unix
touch "${HOME}/.Xauthority"
xauth -f "${HOME}/.Xauthority" add "${HOSTNAME}/unix:${JRMC_DISPLAY}" . "$(mcookie)" >/dev/null 2>&1 || true

args=(
  "${DISPLAY}"
  -geometry "${JRMC_WIDTH}x${JRMC_HEIGHT}"
  -depth 24
  -rfbport "${JRMC_VNC_PORT}"
  -AlwaysShared
  -NeverShared=0
  -SecurityTypes None
  -desktop "JRiver Media Center"
  -auth "${HOME}/.Xauthority"
  -IdleTimeout 0
  -MaxConnectionTime 0
  -MaxDisconnectionTime 0
  -MaxIdleTime 0
  -AcceptSetDesktopSize=1
  -localhost 1
)

exec /usr/bin/Xtigervnc "${args[@]}"
EOF
chmod +x /usr/local/bin/jrmc-vnc-start

cat <<'EOF' >/usr/local/bin/jrmc-openbox-start
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

export HOME="${JRMC_HOME}"
export USER="${JRMC_USER}"
export DISPLAY="${DISPLAY:-:${JRMC_DISPLAY}}"
export XAUTHORITY="${XAUTHORITY:-${JRMC_HOME}/.Xauthority}"

if pgrep -u "${JRMC_USER}" -f '/usr/bin/openbox' >/dev/null 2>&1; then
  exit 0
fi

nohup /usr/bin/openbox >/tmp/jrmc-openbox.log 2>&1 &
EOF
chmod +x /usr/local/bin/jrmc-openbox-start

cat <<'EOF' >/usr/local/bin/jrmc-window-fit
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

app_pid="${1:-}"
if [[ -z "${app_pid}" ]]; then
  exit 0
fi

export HOME="${JRMC_HOME}"
export USER="${JRMC_USER}"
export DISPLAY="${DISPLAY:-:${JRMC_DISPLAY}}"
export XAUTHORITY="${XAUTHORITY:-${JRMC_HOME}/.Xauthority}"

list_client_windows() {
  xprop -root _NET_CLIENT_LIST 2>/dev/null | awk -F '# ' '
    NF > 1 {
      gsub(/,/, "", $2)
      n = split($2, ids, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (ids[i] != "") {
          print ids[i]
        }
      }
    }
  '
}

window_properties() {
  local wid="$1"
  xprop -id "${wid}" WM_CLASS _NET_WM_NAME WM_NAME _NET_WM_PID _NET_WM_STATE 2>/dev/null || true
}

is_jriver_window() {
  local props="$1"
  [[ "${props}" == *'MJFrame'* ]] || [[ "${props}" == *'Media_Center_35'* ]] || [[ "${props}" == *'JRiver Media Center'* ]]
}

is_pid_match() {
  local props="$1"
  [[ -n "${app_pid}" && "${props}" == *"_NET_WM_PID(CARDINAL) = ${app_pid}"* ]]
}

find_window_id() {
  local wid props fallback=""

  while read -r wid; do
    [[ -n "${wid}" ]] || continue
    props="$(window_properties "${wid}")"
    [[ -n "${props}" ]] || continue
    is_jriver_window "${props}" || continue
    if is_pid_match "${props}"; then
      echo "${wid}"
      return 0
    fi
    [[ -n "${fallback}" ]] || fallback="${wid}"
  done < <(list_client_windows)

  if [[ -n "${fallback}" ]]; then
    echo "${fallback}"
    return 0
  fi

  while read -r wid; do
    [[ -n "${wid}" ]] || continue
    props="$(window_properties "${wid}")"
    [[ -n "${props}" ]] || continue
    is_jriver_window "${props}" || continue
    echo "${wid}"
    return 0
  done < <(xdotool search --onlyvisible --pid "${app_pid}" 2>/dev/null || true)

  while read -r wid; do
    [[ -n "${wid}" ]] || continue
    props="$(window_properties "${wid}")"
    [[ -n "${props}" ]] || continue
    is_jriver_window "${props}" || continue
    echo "${wid}"
    return 0
  done < <(xdotool search --onlyvisible --class 'Media_Center_35' 2>/dev/null || true)

  return 1
}

desktop_size() {
  xwininfo -root 2>/dev/null | awk '
    /Width:/ { width=$2 }
    /Height:/ { height=$2 }
    END {
      if (width && height) {
        printf "%s %s\n", width, height
      }
    }
  '
}

fit_window() {
  local wid="$1"
  local width="$2"
  local height="$3"
  local _attempt

  for _attempt in 1 2; do
    xdotool windowactivate "${wid}" >/dev/null 2>&1 || true
    xdotool windowraise "${wid}" >/dev/null 2>&1 || true
    xdotool windowstate --remove MAXIMIZED_VERT "${wid}" >/dev/null 2>&1 || true
    xdotool windowstate --remove MAXIMIZED_HORZ "${wid}" >/dev/null 2>&1 || true
    sleep 0.2
    xdotool windowmove "${wid}" 0 0 >/dev/null 2>&1 || true
    xdotool windowsize "${wid}" "${width}" "${height}" >/dev/null 2>&1 || true
    xdotool windowmove "${wid}" 0 0 >/dev/null 2>&1 || true
    sleep 0.2
    xdotool windowstate --add MAXIMIZED_VERT "${wid}" >/dev/null 2>&1 || true
    xdotool windowstate --add MAXIMIZED_HORZ "${wid}" >/dev/null 2>&1 || true
    sleep 0.2
  done
}

window_id=""
for _i in $(seq 1 120); do
  window_id="$(find_window_id || true)"
  if [[ -n "${window_id}" ]]; then
    break
  fi
  sleep 0.5
done

if [[ -z "${window_id}" ]]; then
  exit 0
fi

last_size=""
while kill -0 "${app_pid}" >/dev/null 2>&1; do
  current_size="$(desktop_size || true)"
  if [[ -z "${current_size}" ]]; then
    sleep 1
    continue
  fi

  if [[ "${current_size}" != "${last_size}" ]]; then
    current_window_id="$(find_window_id || true)"
    if [[ -n "${current_window_id:-}" ]]; then
      window_id="${current_window_id}"
    fi

    read -r width height <<<"${current_size}"
    fit_window "${window_id}" "${width}" "${height}"
    last_size="${current_size}"
  fi

  if ! xwininfo -id "${window_id}" >/dev/null 2>&1; then
    window_id="$(find_window_id || true)"
    if [[ -z "${window_id}" ]]; then
      sleep 1
      continue
    fi
    last_size=""
  fi

  sleep 1
done
EOF
chmod +x /usr/local/bin/jrmc-window-fit

cat <<'EOF' >/usr/local/bin/jrmc-rdp-session-start
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

export HOME="${JRMC_HOME}"
export USER="${JRMC_USER}"
export DISPLAY="${DISPLAY:-:${JRMC_DISPLAY}}"
export XAUTHORITY="${XAUTHORITY:-${JRMC_HOME}/.Xauthority}"

nohup /usr/bin/openbox >/tmp/jrmc-openbox-rdp.log 2>&1 &
sleep 1

/usr/bin/mediacenter35 &
app_pid=$!
/usr/local/bin/jrmc-window-fit "${app_pid}" >/dev/null 2>&1 &
wait "${app_pid}"
EOF
chmod +x /usr/local/bin/jrmc-rdp-session-start

cat <<'EOF' >${APP_HOME}/.xsession
#!/usr/bin/env bash
exec /usr/local/bin/jrmc-rdp-session-start
EOF
chown ${APP_USER}:${APP_USER} ${APP_HOME}/.xsession
chmod 0700 ${APP_HOME}/.xsession

cat <<'EOF' >/usr/local/bin/jrmc-ui-start
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc
export HOME="${JRMC_HOME}"
export USER="${JRMC_USER}"
export DISPLAY=":${JRMC_DISPLAY}"

for _i in $(seq 1 30); do
  xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1 && break
  sleep 0.5
done

/usr/local/bin/jrmc-openbox-start

/usr/bin/mediacenter35 &
app_pid=$!
/usr/local/bin/jrmc-window-fit "${app_pid}" >/dev/null 2>&1 &
wait "${app_pid}"
EOF
chmod +x /usr/local/bin/jrmc-ui-start

cat <<'EOF' >/usr/local/bin/jrmc-mediaserver-start
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc
export HOME="${JRMC_HOME}"
export USER="${JRMC_USER}"
export DISPLAY=":${JRMC_DISPLAY}"

for _i in $(seq 1 30); do
  xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1 && break
  sleep 0.5
done

exec /usr/bin/mediacenter35 /MediaServer
EOF
chmod +x /usr/local/bin/jrmc-mediaserver-start

cat <<'EOF' >/usr/local/bin/jrmc-websockify-start
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

exec /usr/bin/websockify 127.0.0.1:${JRMC_WEBSOCKIFY_PORT} 127.0.0.1:${JRMC_VNC_PORT}
EOF
chmod +x /usr/local/bin/jrmc-websockify-start

cat <<'EOF' >/usr/local/bin/jrmc-native-vnc-cert-ensure
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

install -d -m 755 "$(dirname "${JRMC_NATIVE_VNC_CERT}")"

if [[ ! -s "${JRMC_NATIVE_VNC_CERT}" || ! -s "${JRMC_NATIVE_VNC_KEY}" ]]; then
  host_name="$(hostname -f 2>/dev/null || hostname)"
  host_ip="$(hostname -I | awk '{print $1}')"
  tmp_cfg="$(mktemp)"

  cat >"${tmp_cfg}" <<CFG
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${host_name}

[v3_req]
subjectAltName = DNS:${host_name}${host_ip:+,IP:${host_ip}}
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
CFG

  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 \
    -keyout "${JRMC_NATIVE_VNC_KEY}" \
    -out "${JRMC_NATIVE_VNC_CERT}" \
    -config "${tmp_cfg}" \
    -extensions v3_req >/dev/null 2>&1

  rm -f "${tmp_cfg}"
fi

cat "${JRMC_NATIVE_VNC_CERT}" "${JRMC_NATIVE_VNC_KEY}" >"${JRMC_NATIVE_VNC_PEM}"

chown "${JRMC_USER}:${JRMC_USER}" "${JRMC_NATIVE_VNC_CERT}" "${JRMC_NATIVE_VNC_KEY}" "${JRMC_NATIVE_VNC_PEM}"
chmod 0644 "${JRMC_NATIVE_VNC_CERT}"
chmod 0600 "${JRMC_NATIVE_VNC_KEY}" "${JRMC_NATIVE_VNC_PEM}"
EOF
chmod +x /usr/local/bin/jrmc-native-vnc-cert-ensure

cat <<'EOF' >/usr/local/bin/jrmc-native-vnc-auth
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

IFS= read -r username || exit 1
IFS= read -r password || exit 1

if [[ ! "${username}" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; then
  exit 1
fi

htpasswd -vb "${JRMC_VNC_HTPASSWD}" "${username}" "${password}" >/dev/null 2>&1
EOF
chmod +x /usr/local/bin/jrmc-native-vnc-auth

cat <<'EOF' >/usr/local/bin/jrmc-native-vnc-start
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

export HOME="${JRMC_HOME}"
export USER="${JRMC_USER}"
export DISPLAY=":${JRMC_DISPLAY}"
export XAUTHORITY="${JRMC_HOME}/.Xauthority"

for _i in $(seq 1 30); do
  xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1 && break
  sleep 0.5
done

if ! xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
  echo "JRMC display ${DISPLAY} is not ready for native VNC." >&2
  exit 1
fi

args=(
  -display "${DISPLAY}"
  -rfbport "${JRMC_NATIVE_VNC_PORT}"
  -SecurityTypes "${JRMC_NATIVE_VNC_SECURITY}"
  -PAMService "${JRMC_VNC_PAM_SERVICE}"
  -PlainUsers '*'
  -AlwaysShared
)

if [[ "${JRMC_NATIVE_VNC_SECURITY}" == X509* ]]; then
  /usr/local/bin/jrmc-native-vnc-cert-ensure
  args+=(
    -X509Cert "${JRMC_NATIVE_VNC_CERT}"
    -X509Key "${JRMC_NATIVE_VNC_KEY}"
  )
fi

exec /usr/bin/x0vncserver "${args[@]}"
EOF
chmod +x /usr/local/bin/jrmc-native-vnc-start

cat <<'EOF' >/usr/local/bin/jrmc-set-web-credentials
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

username="${1:-}"
password="${2:-}"

if [[ -z "${username}" || -z "${password}" ]]; then
  echo "Usage: jrmc-set-web-credentials <username> <password>" >&2
  exit 1
fi

if [[ ! "${username}" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; then
  echo "Username must match [A-Za-z0-9._-] and be 3-32 chars." >&2
  exit 1
fi

htpasswd -b -c -5 "${JRMC_WEB_HTPASSWD}" "${username}" "${password}" >/dev/null 2>&1
htpasswd -b -c -5 "${JRMC_VNC_HTPASSWD}" "${username}" "${password}" >/dev/null 2>&1
printf '%s:%s\n' "${JRMC_NATIVE_RDP_USER}" "${password}" | chpasswd
touch "${JRMC_BOOTSTRAP_FILE}"
chown root:www-data "${JRMC_WEB_HTPASSWD}"
chmod 0640 "${JRMC_WEB_HTPASSWD}"
chown "${JRMC_USER}:${JRMC_USER}" "${JRMC_VNC_HTPASSWD}"
chmod 0600 "${JRMC_VNC_HTPASSWD}"
chmod 0644 "${JRMC_BOOTSTRAP_FILE}"

cat <<CREDS >/root/jrmc.creds
JRiver Media Center Web Access
==============================
URL: https://$(hostname -I | awk '{print $1}'):${JRMC_WEB_PORT}/setup/
Username: ${username}
Password: ${password}

Default mode: Media Server
Interactive UI: open Dashboard, then Launch JRMC UI.
Native RDP: optional from Dashboard on port ${JRMC_NATIVE_RDP_PORT} for Remmina using user ${JRMC_NATIVE_RDP_USER} and the same password as Dashboard.
Native VNC: optional from Dashboard on port ${JRMC_NATIVE_VNC_PORT} while UI mode is active for TigerVNC compatibility using TLSPlain and the same Dashboard credentials.
CREDS

systemctl reload nginx
EOF
chmod +x /usr/local/bin/jrmc-set-web-credentials

cat <<'EOF' >/usr/local/bin/jrmc-mode
#!/usr/bin/env bash
set -euo pipefail

source /etc/default/jrmc

mode="${1:-status}"

case "${mode}" in
  ui)
    systemctl stop jrmc-mediaserver.service || true
    systemctl restart jrmc-vnc.service
    systemctl restart jrmc-websockify.service
    systemctl restart jrmc-ui.service
    if [[ "${JRMC_NATIVE_VNC_ENABLED:-0}" == "1" ]]; then
      systemctl restart jrmc-native-vnc.service
    else
      systemctl stop jrmc-native-vnc.service || true
    fi
    echo "JRMC UI mode started."
    ;;
  mediaserver)
    systemctl stop jrmc-native-vnc.service jrmc-ui.service jrmc-websockify.service || true
    systemctl restart jrmc-vnc.service
    systemctl restart jrmc-mediaserver.service
    echo "JRMC Media Server mode started."
    ;;
  stop-ui)
    systemctl stop jrmc-native-vnc.service jrmc-ui.service jrmc-websockify.service jrmc-vnc.service || true
    echo "JRMC UI mode stopped."
    ;;
  stop-server)
    systemctl stop jrmc-mediaserver.service || true
    systemctl stop jrmc-vnc.service || true
    echo "JRMC Media Server mode stopped."
    ;;
  status)
    echo "jrmc-mediaserver: $(systemctl is-active jrmc-mediaserver.service 2>/dev/null || true)"
    echo "jrmc-vnc: $(systemctl is-active jrmc-vnc.service 2>/dev/null || true)"
    echo "jrmc-websockify: $(systemctl is-active jrmc-websockify.service 2>/dev/null || true)"
    echo "jrmc-ui: $(systemctl is-active jrmc-ui.service 2>/dev/null || true)"
    echo "jrmc-native-vnc: $(systemctl is-active jrmc-native-vnc.service 2>/dev/null || true)"
    echo "xrdp: $(systemctl is-active xrdp.service 2>/dev/null || true)"
    echo "native-vnc: $([[ "${JRMC_NATIVE_VNC_ENABLED:-0}" == "1" ]] && echo enabled || echo disabled)"
    echo "native-rdp: $([[ "${JRMC_NATIVE_RDP_ENABLED:-0}" == "1" ]] && echo enabled || echo disabled)"
    ;;
  *)
    echo "Usage: jrmc-mode {ui|mediaserver|stop-ui|stop-server|status}" >&2
    exit 1
    ;;
esac
EOF
chmod +x /usr/local/bin/jrmc-mode

cat <<'EOF' >/usr/local/bin/jrmc-direct-vnc
#!/usr/bin/env bash
set -euo pipefail

source /etc/default/jrmc

action="${1:-status}"

update_default() {
  local key="$1"
  local value="$2"
  python3 - "$key" "$value" <<'PY'
import sys
from pathlib import Path

path = Path('/etc/default/jrmc')
key = sys.argv[1]
value = sys.argv[2]
lines = path.read_text().splitlines()
new_lines = []
found = False
for line in lines:
    if line.startswith(f"{key}="):
        new_lines.append(f'{key}="{value}"')
        found = True
    else:
        new_lines.append(line)
if not found:
    new_lines.append(f'{key}="{value}"')
path.write_text("\n".join(new_lines) + "\n")
PY
}

restart_ui_stack_if_needed() {
  local ui_active=0
  source /etc/default/jrmc

  if systemctl is-active --quiet jrmc-ui.service; then
    ui_active=1
  fi

  if (( ui_active )); then
    if [[ "${JRMC_NATIVE_VNC_ENABLED:-0}" == "1" ]]; then
      systemctl restart jrmc-native-vnc.service
    else
      systemctl stop jrmc-native-vnc.service || true
    fi
  fi
}

print_status() {
  source /etc/default/jrmc
  local state="disabled"
  if [[ "${JRMC_NATIVE_VNC_ENABLED:-0}" == "1" ]]; then
    state="enabled"
  fi

  echo "native-vnc: ${state}"
  echo "ui-mode: $(systemctl is-active jrmc-ui.service 2>/dev/null || true)"
  echo "native-vnc-service: $(systemctl is-active jrmc-native-vnc.service 2>/dev/null || true)"
  if [[ "${state}" == "enabled" ]] && systemctl is-active --quiet jrmc-native-vnc.service; then
    echo "endpoint: $(hostname -I | awk '{print $1}'):${JRMC_NATIVE_VNC_PORT}"
    echo "security: ${JRMC_NATIVE_VNC_SECURITY} using the same username/password as Dashboard"
    echo "backend: x0vncserver desktop-sharing backend for TigerVNC compatibility"
  else
    echo "endpoint: unavailable until native VNC is enabled and UI mode is running"
  fi
}

case "${action}" in
  enable)
    update_default JRMC_NATIVE_VNC_ENABLED 1
    restart_ui_stack_if_needed
    echo "Native VNC enabled. Port ${JRMC_NATIVE_VNC_PORT} will accept the same Dashboard username/password with ${JRMC_NATIVE_VNC_SECURITY} while UI mode is active. If the UI was already running, the x0vncserver desktop-sharing service was started immediately."
    ;;
  disable)
    update_default JRMC_NATIVE_VNC_ENABLED 0
    restart_ui_stack_if_needed
    echo "Native VNC disabled. Browser noVNC remains available through the Dashboard. If the UI was already running, the native desktop-sharing service was stopped immediately."
    ;;
  status)
    print_status
    ;;
  *)
    echo "Usage: jrmc-direct-vnc {enable|disable|status}" >&2
    exit 1
    ;;
esac
EOF
chmod +x /usr/local/bin/jrmc-direct-vnc

cat <<'EOF' >/usr/local/bin/jrmc-direct-rdp
#!/usr/bin/env bash
set -euo pipefail

source /etc/default/jrmc

action="${1:-status}"

update_default() {
  local key="$1"
  local value="$2"
  python3 - "$key" "$value" <<'PY'
import sys
from pathlib import Path

path = Path('/etc/default/jrmc')
key = sys.argv[1]
value = sys.argv[2]
lines = path.read_text().splitlines()
new_lines = []
found = False
for line in lines:
    if line.startswith(f"{key}="):
        new_lines.append(f'{key}="{value}"')
        found = True
    else:
        new_lines.append(line)
if not found:
    new_lines.append(f'{key}="{value}"')
path.write_text("\n".join(new_lines) + "\n")
PY
}

print_status() {
  source /etc/default/jrmc
  local state="disabled"
  if [[ "${JRMC_NATIVE_RDP_ENABLED:-0}" == "1" ]]; then
    state="enabled"
  fi

  echo "native-rdp: ${state}"
  echo "xrdp-service: $(systemctl is-active xrdp.service 2>/dev/null || true)"
  echo "xrdp-sesman: $(systemctl is-active xrdp-sesman.service 2>/dev/null || true)"
  if [[ "${state}" == "enabled" ]] && systemctl is-active --quiet xrdp.service; then
    echo "endpoint: $(hostname -I | awk '{print $1}'):${JRMC_NATIVE_RDP_PORT}"
    echo "username: ${JRMC_NATIVE_RDP_USER}"
    echo "password: same password as Dashboard"
    echo "backend: xrdp + xorgxrdp session for Remmina and other RDP clients"
  else
    echo "endpoint: unavailable until native RDP is enabled"
  fi
}

case "${action}" in
  enable)
    update_default JRMC_NATIVE_RDP_ENABLED 1
    systemctl enable --now xrdp-sesman.service xrdp.service
    echo "Native RDP enabled. Connect to port ${JRMC_NATIVE_RDP_PORT} with username ${JRMC_NATIVE_RDP_USER} and the same password used for Dashboard."
    ;;
  disable)
    update_default JRMC_NATIVE_RDP_ENABLED 0
    systemctl disable --now xrdp.service xrdp-sesman.service || true
    echo "Native RDP disabled. Browser noVNC and optional native VNC remain available through the Dashboard."
    ;;
  status)
    print_status
    ;;
  *)
    echo "Usage: jrmc-direct-rdp {enable|disable|status}" >&2
    exit 1
    ;;
esac
EOF
chmod +x /usr/local/bin/jrmc-direct-rdp

cat <<'EOF' >/usr/local/bin/jrmc-activate
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

restore_file="${1:-}"
if [[ -z "${restore_file}" || ! -f "${restore_file}" ]]; then
  echo "Usage: jrmc-activate /path/to/license.mjr" >&2
  exit 1
fi

systemctl stop jrmc-ui.service jrmc-websockify.service jrmc-vnc.service jrmc-mediaserver.service || true
runuser -u "${JRMC_USER}" -- env HOME="${JRMC_HOME}" /usr/bin/mediacenter35 /RestoreFromFile "${restore_file}"
systemctl start jrmc-mediaserver.service
echo "Activation import complete. JRMC Media Server restarted."
EOF
chmod +x /usr/local/bin/jrmc-activate

cat <<'EOF' >${CGI_BIN}/jrmc-setup.py
#!/usr/bin/env python3
import html
import os
import re
import subprocess
import sys
from urllib.parse import parse_qs


def respond(body: str) -> None:
    print("Content-Type: text/html")
    print()
    print(body)


if os.environ.get("REQUEST_METHOD", "GET").upper() != "POST":
    respond("<html><body><h1>Method Not Allowed</h1></body></html>")
    sys.exit(0)

length = int(os.environ.get("CONTENT_LENGTH", "0") or "0")
data = parse_qs(sys.stdin.read(length), keep_blank_values=True)
username = data.get("username", [""])[0].strip()
password = data.get("password", [""])[0]
confirm = data.get("confirm_password", [""])[0]

errors = []
if not re.fullmatch(r"[A-Za-z0-9._-]{3,32}", username):
    errors.append("Username must be 3-32 characters using letters, numbers, dot, dash, or underscore.")
if len(password) < 8:
    errors.append("Password must be at least 8 characters.")
if password != confirm:
    errors.append("Passwords do not match.")

if errors:
    items = "".join(f"<li>{html.escape(err)}</li>" for err in errors)
    respond(f"<html><body><h1>Setup failed</h1><ul>{items}</ul><p><a href='/setup/'>Return to setup</a></p></body></html>")
    sys.exit(0)

subprocess.run(["sudo", "/usr/local/bin/jrmc-set-web-credentials", username, password], check=True)
respond(
    "<html><body><h1>JRMC web access configured</h1>"
    "<p>Open <a href='/dashboard/'>Dashboard</a> and sign in with the credentials you just created.</p>"
    "<p>The container starts in Media Server mode. Use Dashboard to launch the interactive UI.</p>"
    "</body></html>"
)
EOF
chmod +x ${CGI_BIN}/jrmc-setup.py

cat <<'EOF' >${CGI_BIN}/jrmc-control.py
#!/usr/bin/env python3
import html
import os
import subprocess
from urllib.parse import parse_qs


query = parse_qs(os.environ.get("QUERY_STRING", ""), keep_blank_values=True)
action = query.get("action", [""])[0]

mapping = {
    "start-ui": ["sudo", "/usr/local/bin/jrmc-mode", "ui"],
    "stop-ui": ["sudo", "/usr/local/bin/jrmc-mode", "stop-ui"],
    "start-server": ["sudo", "/usr/local/bin/jrmc-mode", "mediaserver"],
    "stop-server": ["sudo", "/usr/local/bin/jrmc-mode", "stop-server"],
    "enable-direct-rdp": ["sudo", "/usr/local/bin/jrmc-direct-rdp", "enable"],
    "disable-direct-rdp": ["sudo", "/usr/local/bin/jrmc-direct-rdp", "disable"],
    "direct-rdp-status": ["sudo", "/usr/local/bin/jrmc-direct-rdp", "status"],
    "enable-direct-vnc": ["sudo", "/usr/local/bin/jrmc-direct-vnc", "enable"],
    "disable-direct-vnc": ["sudo", "/usr/local/bin/jrmc-direct-vnc", "disable"],
    "direct-vnc-status": ["sudo", "/usr/local/bin/jrmc-direct-vnc", "status"],
}

print("Content-Type: text/html")
print()

if action not in mapping:
    print("<html><body><h1>Invalid action</h1><p><a href='/dashboard/'>Back</a></p></body></html>")
    raise SystemExit(0)

result = subprocess.run(mapping[action], capture_output=True, text=True, check=False)
stdout = html.escape((result.stdout or "").strip())
stderr = html.escape((result.stderr or "").strip())
status = "completed" if result.returncode == 0 else "failed"
detail = stdout or stderr or "No output"
print(f"<html><body><h1>Action {status}</h1><pre>{detail}</pre><p><a href='/dashboard/'>Back to dashboard</a></p></body></html>")
EOF
chmod +x ${CGI_BIN}/jrmc-control.py

cat <<'EOF' >${WEB_ROOT}/setup/index.html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>JRiver Media Center Setup</title>
  <style>
    body{font-family:system-ui,sans-serif;max-width:720px;margin:3rem auto;padding:0 1rem;background:#0f172a;color:#e2e8f0}
    .card{background:#111827;border:1px solid #334155;border-radius:12px;padding:1.5rem}
    input{width:100%;padding:.8rem;margin:.4rem 0 1rem;border-radius:8px;border:1px solid #475569;background:#020617;color:#e2e8f0}
    button{padding:.9rem 1.2rem;border:0;border-radius:8px;background:#2563eb;color:white;font-weight:600;cursor:pointer}
    a{color:#93c5fd}
  </style>
</head>
<body>
  <div class="card">
    <h1>JRiver Media Center Web Setup</h1>
    <p>Create the initial noVNC dashboard account. Browser access is protected by HTTPS with a self-signed certificate and HTTP basic auth.</p>
    <form method="post" action="/cgi-bin/jrmc-setup.py">
      <label>Username</label>
      <input name="username" minlength="3" maxlength="32" required>
      <label>Password</label>
      <input type="password" name="password" minlength="8" required>
      <label>Confirm password</label>
      <input type="password" name="confirm_password" minlength="8" required>
      <button type="submit">Create web credentials</button>
    </form>
    <p>After setup, sign in at <a href="/dashboard/">Dashboard</a>, then launch the JRMC UI.</p>
  </div>
</body>
</html>
EOF

cat <<'EOF' >${WEB_ROOT}/dashboard/index.html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>JRMC Dashboard</title>
  <style>
    body{font-family:system-ui,sans-serif;max-width:900px;margin:3rem auto;padding:0 1rem;background:#0f172a;color:#e2e8f0}
    .card{background:#111827;border:1px solid #334155;border-radius:12px;padding:1.5rem;margin-bottom:1rem}
    .actions{display:flex;gap:.75rem;flex-wrap:wrap}
    a{display:inline-block;padding:.9rem 1.2rem;border-radius:8px;background:#2563eb;color:white;text-decoration:none}
    .alt{background:#475569}
    code{background:#020617;padding:.15rem .35rem;border-radius:4px}
  </style>
</head>
<body>
  <div class="card">
    <h1>JRiver Media Center Dashboard</h1>
    <p>Default runtime mode is <strong>Media Server</strong>. Launch the interactive UI only when needed for library setup and administration.</p>
    <div class="actions">
      <a href="/cgi-bin/jrmc-control.py?action=start-ui">Launch JRMC UI</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=start-server">Return to Media Server</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=stop-ui">Stop UI</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=stop-server">Stop Media Server</a>
    </div>
  </div>
  <div class="card">
    <h2>Interactive Session</h2>
    <p>After launching the UI, open noVNC in the browser, enable native RDP for Remmina, or enable native VNC for TigerVNC-compatible desktop clients.</p>
    <div class="actions">
      <a href="/novnc/vnc.html?autoconnect=1&resize=remote&path=/websockify">Open noVNC</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=enable-direct-rdp">Enable Native RDP</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=disable-direct-rdp">Disable Native RDP</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=direct-rdp-status">Native RDP Status</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=enable-direct-vnc">Enable Native VNC</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=disable-direct-vnc">Disable Native VNC</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=direct-vnc-status">Native VNC Status</a>
    </div>
    <p>Native RDP listens on port <code>3389</code> for Remmina and other RDP clients. Sign in as <code>jriver</code> with the same password used for Dashboard.</p>
    <p>Native VNC listens on port <code>5902</code>, uses <code>TLSPlain</code> with the same Dashboard username and password, and is only reachable while JRMC UI mode is active. Browser noVNC keeps the dedicated Xtigervnc backend, while TigerVNC-compatible native clients use a separate <code>x0vncserver</code> desktop-sharing backend.</p>
    <p>Changing native VNC state while the UI is already running starts or stops the native desktop-sharing service without interrupting the browser session.</p>
  </div>
  <div class="card">
    <h2>Activation</h2>
    <p>Import a <code>.mjr</code> license file from inside the container with <code>jrmc-activate /path/to/file.mjr</code>.</p>
    <p>Local admin helper: <code>jrmc-configure</code></p>
  </div>
</body>
</html>
EOF

cat <<'EOF' >/etc/nginx/sites-available/jrmc.conf
server {
    listen 5800 ssl;
    server_name _;

    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    root /usr/share/jrmc-web;
    index index.html;

    location = / {
        return 302 /setup/;
    }

    location /setup/ {
        alias /usr/share/jrmc-web/setup/;
        try_files $uri $uri/ /setup/index.html;
    }

    location /dashboard/ {
        auth_basic "JRMC";
        auth_basic_user_file /etc/nginx/jrmc.htpasswd;
        alias /usr/share/jrmc-web/dashboard/;
        try_files $uri $uri/ /dashboard/index.html;
    }

    location /novnc/ {
        auth_basic "JRMC";
        auth_basic_user_file /etc/nginx/jrmc.htpasswd;
        alias /usr/share/novnc/;
        try_files $uri $uri/ =404;
    }

    location /websockify {
        auth_basic "JRMC";
        auth_basic_user_file /etc/nginx/jrmc.htpasswd;
        proxy_pass http://127.0.0.1:6080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 61s;
        proxy_buffering off;
    }

    location = /cgi-bin/jrmc-setup.py {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/lib/cgi-bin/jrmc-setup.py;
        fastcgi_pass unix:/run/fcgiwrap.socket;
    }

    location = /cgi-bin/jrmc-control.py {
        auth_basic "JRMC";
        auth_basic_user_file /etc/nginx/jrmc.htpasswd;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/lib/cgi-bin/jrmc-control.py;
        fastcgi_pass unix:/run/fcgiwrap.socket;
    }
}
EOF
ln -sf /etc/nginx/sites-available/jrmc.conf /etc/nginx/sites-enabled/jrmc.conf
rm -f /etc/nginx/sites-enabled/default

cat <<'EOF' >/etc/pam.d/jrmc-vnc
auth required pam_pwdfile.so pwdfile=/etc/jrmc/native-vnc.htpasswd
account required pam_permit.so
session required pam_permit.so
password required pam_deny.so
EOF

sed -i 's/^port=.*/port=3389/' /etc/xrdp/xrdp.ini
systemctl disable --now xrdp.service xrdp-sesman.service >/dev/null 2>&1 || true

cat <<'EOF' >/etc/sudoers.d/jrmc-web
www-data ALL=(root) NOPASSWD: /usr/local/bin/jrmc-mode, /usr/local/bin/jrmc-direct-rdp, /usr/local/bin/jrmc-direct-vnc, /usr/local/bin/jrmc-set-web-credentials
EOF
chmod 0440 /etc/sudoers.d/jrmc-web

cat <<EOF >/etc/systemd/system/jrmc-vnc.service
[Unit]
Description=JRiver Media Center local VNC backend
After=network.target

[Service]
Type=simple
User=${APP_USER}
ExecStartPre=-/bin/sh -c 'rm -f /tmp/.X${JRMC_DISPLAY}-lock /tmp/.X11-unix/X${JRMC_DISPLAY}'
ExecStart=/usr/local/bin/jrmc-vnc-start
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/jrmc-native-vnc.service
[Unit]
Description=JRiver Media Center native VNC compatibility backend
After=jrmc-vnc.service jrmc-ui.service
Requires=jrmc-vnc.service

[Service]
Type=simple
ExecStart=/usr/local/bin/jrmc-native-vnc-start
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' >/etc/systemd/system/jrmc-websockify.service
[Unit]
Description=JRiver Media Center noVNC websocket proxy
After=jrmc-vnc.service
Requires=jrmc-vnc.service

[Service]
Type=simple
ExecStart=/usr/local/bin/jrmc-websockify-start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/jrmc-ui.service
[Unit]
Description=JRiver Media Center interactive UI
After=jrmc-vnc.service
Requires=jrmc-vnc.service

[Service]
Type=simple
User=${APP_USER}
ExecStart=/usr/local/bin/jrmc-ui-start
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/jrmc-mediaserver.service
[Unit]
Description=JRiver Media Center Media Server mode
After=network.target jrmc-vnc.service
Requires=jrmc-vnc.service

[Service]
Type=simple
User=${APP_USER}
ExecStart=/usr/local/bin/jrmc-mediaserver-start
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

rm -f /tmp/.X*-lock /tmp/.X11-unix/X*
systemctl daemon-reload
systemctl enable --now fcgiwrap.socket
systemctl enable nginx jrmc-mediaserver.service
systemctl restart nginx
systemctl restart jrmc-mediaserver.service
msg_ok "Configured Browser-first JRMC access on https://IP:${JRMC_WEB_PORT}/setup/"

msg_info "Creating Helper Commands"
cat <<'EOF' >/usr/local/bin/jrmc-configure
#!/usr/bin/env bash
set -euo pipefail

echo "JRiver Media Center Configuration"
echo "==================================="
echo
echo "Web setup URL:        https://<container-ip>:5800/setup/"
echo "Default mode:         Media Server"
echo "Interactive UI:       noVNC via Dashboard with remote desktop resize"
echo "Native RDP:           Optional on port 3389 for Remmina using user ${APP_USER}"
echo "Native VNC:           Optional on port 5902 with TLSPlain for TigerVNC while UI mode is active"
echo

PS3="Select an option: "
select opt in \
  "Set web credentials" \
  "Start JRMC UI mode" \
  "Return to Media Server mode" \
  "Enable Native RDP" \
  "Disable Native RDP" \
  "Show Native RDP status" \
  "Enable Native VNC" \
  "Disable Native VNC" \
  "Show Native VNC status" \
  "Show service status" \
  "Import .mjr activation file" \
  "Update JRiver Media Center" \
  "Exit"; do
  case $opt in
  "Set web credentials")
    read -r -p "Enter new web username: " user
    read -r -s -p "Enter new web password: " pass
    echo
    /usr/local/bin/jrmc-set-web-credentials "$user" "$pass"
    echo "Web credentials updated."
    ;;
  "Start JRMC UI mode")
    /usr/local/bin/jrmc-mode ui
    ;;
  "Return to Media Server mode")
    /usr/local/bin/jrmc-mode mediaserver
    ;;
  "Enable Native RDP")
    /usr/local/bin/jrmc-direct-rdp enable
    ;;
  "Disable Native RDP")
    /usr/local/bin/jrmc-direct-rdp disable
    ;;
  "Show Native RDP status")
    /usr/local/bin/jrmc-direct-rdp status
    ;;
  "Enable Native VNC")
    /usr/local/bin/jrmc-direct-vnc enable
    ;;
  "Disable Native VNC")
    /usr/local/bin/jrmc-direct-vnc disable
    ;;
  "Show Native VNC status")
    /usr/local/bin/jrmc-direct-vnc status
    ;;
  "Show service status")
    /usr/local/bin/jrmc-mode status
    ;;
  "Import .mjr activation file")
    read -r -p "Path to .mjr file: " mjr
    /usr/local/bin/jrmc-activate "$mjr"
    ;;
  "Update JRiver Media Center")
    runuser -l jriver -- /usr/local/bin/installJRMC \
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
chmod +x /usr/local/bin/jrmc-configure
ln -sf /usr/local/bin/jrmc-configure /usr/bin/jrmc-configure
ln -sf /usr/local/bin/jrmc-configure /usr/bin/jriver-configure
msg_ok "Created Helper Commands"

motd_ssh
customize
cleanup_lxc
