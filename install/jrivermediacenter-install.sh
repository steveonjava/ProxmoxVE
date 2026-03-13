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
RUNTIME_DIR="${APP_HOME}/.cache/jrmc"
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
  "${APP_HOME}/.cache" \
  "${APP_HOME}/.config" \
  "${RUNTIME_DIR}" \
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
JRMC_UI_SCALE="100"
JRMC_MODE="mediaserver"
JRMC_WEB_HTPASSWD="/etc/nginx/jrmc.htpasswd"
JRMC_VNC_HTPASSWD="${CONFIG_DIR}/native-vnc.htpasswd"
JRMC_BOOTSTRAP_FILE="${CONFIG_DIR}/bootstrap-complete"
JRMC_NATIVE_VNC_ENABLED="0"
JRMC_NATIVE_RDP_ENABLED="0"
JRMC_NATIVE_RDP_USER="${APP_USER}"
JRMC_VNC_PAM_SERVICE="jrmc-vnc"
JRMC_NATIVE_VNC_SECURITY="TLSPlain"
JRMC_NATIVE_VNC_PIDFILE="${CONFIG_DIR}/native-vnc.pid"
JRMC_RUNTIME_DIR="${RUNTIME_DIR}"
JRMC_UI_PIDFILE="${RUNTIME_DIR}/ui.pid"
JRMC_RDP_PIDFILE="${RUNTIME_DIR}/rdp.pid"
JRMC_RDP_OPENBOX_PIDFILE="${RUNTIME_DIR}/rdp-openbox.pid"
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

if ! read -r jrmc_scale_width jrmc_scale_height < <(/usr/local/bin/jrmc-scale-profile size 2>/dev/null); then
  jrmc_scale_width="${JRMC_WIDTH}"
  jrmc_scale_height="${JRMC_HEIGHT}"
fi

mkdir -p /tmp/.X11-unix
touch "${HOME}/.Xauthority"
xauth -f "${HOME}/.Xauthority" add "${HOSTNAME}/unix:${JRMC_DISPLAY}" . "$(mcookie)" >/dev/null 2>&1 || true

args=(
  "${DISPLAY}"
  -geometry "${jrmc_scale_width}x${jrmc_scale_height}"
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

cat <<'EOF' >/usr/local/bin/jrmc-scale-profile
#!/usr/bin/env python3
import math
import os
import subprocess
import sys
from pathlib import Path

ALLOWED_SCALES = (100, 125, 150, 175, 200)


def load_defaults() -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in Path("/etc/default/jrmc").read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip('"').strip("'")
    return values


def int_value(values: dict[str, str], key: str, default: int) -> int:
    try:
        return int(str(values.get(key, default)).strip())
    except (TypeError, ValueError):
        return default


def build_profile(values: dict[str, str]) -> dict[str, float | int | str]:
    scale = int_value(values, "JRMC_UI_SCALE", 100)
    if scale not in ALLOWED_SCALES:
        scale = 100

    base_width = max(800, int_value(values, "JRMC_WIDTH", 1440))
    base_height = max(600, int_value(values, "JRMC_HEIGHT", 900))
    width = max(640, math.floor((base_width * scale / 100) + 0.5))
    height = max(480, math.floor((base_height * scale / 100) + 0.5))
    dpi = max(96, math.floor((96 * scale / 100) + 0.5))
    gdk_scale = 2 if scale >= 175 else 1
    gdk_dpi_scale = (scale / 100) / gdk_scale
    qt_scale_factor = scale / 100
    cursor_size = max(24, math.floor((24 * scale / 100) + 0.5))
    fbmm_width = max(120, math.floor((width * 25.4 / dpi) + 0.5))
    fbmm_height = max(90, math.floor((height * 25.4 / dpi) + 0.5))
    display = values.get("JRMC_DISPLAY", "1")
    return {
        "scale": scale,
        "base_width": base_width,
        "base_height": base_height,
        "width": width,
        "height": height,
        "dpi": dpi,
        "gdk_scale": gdk_scale,
        "gdk_dpi_scale": gdk_dpi_scale,
        "qt_scale_factor": qt_scale_factor,
        "cursor_size": cursor_size,
        "fbmm_width": fbmm_width,
        "fbmm_height": fbmm_height,
        "shared_display": f":{display}",
        "home": values.get("JRMC_HOME", "/home/jriver"),
    }


def format_float(value: float) -> str:
    return f"{value:.3f}".rstrip("0").rstrip(".")


def emit_exports(profile: dict[str, float | int | str]) -> None:
    print(f'export JRMC_UI_SCALE_ACTIVE="{profile["scale"]}"')
    print(f'export JRMC_SCALE_WIDTH="{profile["width"]}"')
    print(f'export JRMC_SCALE_HEIGHT="{profile["height"]}"')
    print(f'export JRMC_SCALE_DPI="{profile["dpi"]}"')
    print(f'export JRMC_SCALE_FBMM_WIDTH="{profile["fbmm_width"]}"')
    print(f'export JRMC_SCALE_FBMM_HEIGHT="{profile["fbmm_height"]}"')
    print(f'export GDK_SCALE="{profile["gdk_scale"]}"')
    print(f'export GDK_DPI_SCALE="{format_float(float(profile["gdk_dpi_scale"]))}"')
    print(f'export QT_SCALE_FACTOR="{format_float(float(profile["qt_scale_factor"]))}"')
    print('export QT_AUTO_SCREEN_SCALE_FACTOR="0"')
    print('export QT_ENABLE_HIGHDPI_SCALING="1"')
    print('export QT_SCALE_FACTOR_ROUNDING_POLICY="RoundPreferFloor"')
    print(f'export XCURSOR_SIZE="{profile["cursor_size"]}"')


def apply_session(values: dict[str, str], profile: dict[str, float | int | str]) -> int:
    env = os.environ.copy()
    display = env.get("DISPLAY") or str(profile["shared_display"])
    env["DISPLAY"] = display
    env["XAUTHORITY"] = env.get("XAUTHORITY") or f'{profile["home"]}/.Xauthority'

    resources = (
        f'Xft.dpi: {profile["dpi"]}\n'
        f'Xcursor.size: {profile["cursor_size"]}\n'
    )
    subprocess.run(["xrdb", "-quiet", "-merge", "-"], input=resources, text=True, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    subprocess.run(["xrandr", "--dpi", str(profile["dpi"])], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    subprocess.run(["xrandr", "--fbmm", f'{profile["fbmm_width"]}x{profile["fbmm_height"]}'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    if display == str(profile["shared_display"]):
        geometry = f'{profile["width"]}x{profile["height"]}'
        subprocess.run(["xrandr", "--fb", geometry], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
      subprocess.run(["xrandr", "--size", geometry], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    return 0


def print_summary(profile: dict[str, float | int | str]) -> None:
    print(f'ui-scale: {profile["scale"]}%')
    print(f'vnc-framebuffer: {profile["width"]}x{profile["height"]} (base {profile["base_width"]}x{profile["base_height"]})')
    print(f'session-dpi: {profile["dpi"]}')
    print(f'gtk-hints: GDK_SCALE={profile["gdk_scale"]} GDK_DPI_SCALE={format_float(float(profile["gdk_dpi_scale"]))}')
    print(f'qt-hints: QT_SCALE_FACTOR={format_float(float(profile["qt_scale_factor"]))}')
    print('client-guidance: VNC mode renders a larger server framebuffer as scale increases. Let noVNC scale the view to fit and prefer 100% / 1:1 scaling in TigerVNC and Remmina for the sharpest result.')


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "summary"
    values = load_defaults()
    profile = build_profile(values)

    if action == "exports":
        emit_exports(profile)
        return 0
    if action == "size":
        print(f'{profile["width"]} {profile["height"]}')
        return 0
    if action == "geometry":
        print(f'{profile["width"]}x{profile["height"]}')
        return 0
    if action == "summary":
        print_summary(profile)
        return 0
    if action == "apply-session":
        return apply_session(values, profile)

    print("Usage: jrmc-scale-profile {exports|size|geometry|summary|apply-session}", file=sys.stderr)
    return 1


raise SystemExit(main())
EOF
chmod +x /usr/local/bin/jrmc-scale-profile

cat <<'EOF' >/usr/local/bin/jrmc-scale-watch
#!/usr/bin/env bash
set -euo pipefail

last_signature=""
while true; do
  signature="$(grep -E '^(JRMC_UI_SCALE|JRMC_WIDTH|JRMC_HEIGHT)=' /etc/default/jrmc 2>/dev/null | tr '\n' '|')"
  if [[ "${signature}" != "${last_signature}" ]]; then
    /usr/local/bin/jrmc-scale-profile apply-session >/dev/null 2>&1 || true
    last_signature="${signature}"
  fi
  sleep 2
done
EOF
chmod +x /usr/local/bin/jrmc-scale-watch

cat <<'EOF' >/usr/local/bin/jrmc-scale
#!/usr/bin/env bash
set -euo pipefail

source /etc/default/jrmc

action="${1:-status}"

allowed_scale() {
  case "${1:-}" in
    100|125|150|175|200) return 0 ;;
    *) return 1 ;;
  esac
}

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

apply_shared_display_now() {
  if systemctl is-active --quiet jrmc-vnc.service; then
    runuser -u "${JRMC_USER}" -- env \
      HOME="${JRMC_HOME}" \
      USER="${JRMC_USER}" \
      DISPLAY=":${JRMC_DISPLAY}" \
      XAUTHORITY="${JRMC_HOME}/.Xauthority" \
      /usr/local/bin/jrmc-scale-profile apply-session >/dev/null 2>&1 || true
  fi
}

restart_vnc_mode_if_active() {
  local active_mode=""
  active_mode="$(/usr/local/bin/jrmc-mode status 2>/dev/null | awk -F': ' '/^active-mode:/ {print $2; exit}')"
  if [[ "${active_mode}" == "vnc" ]]; then
    /usr/local/bin/jrmc-mode vnc >/dev/null
    return 0
  fi
  return 1
}

print_status() {
  /usr/local/bin/jrmc-scale-profile summary
  echo "shared-ui: $(systemctl is-active jrmc-ui.service 2>/dev/null || true)"
  echo "shared-vnc-backend: $(systemctl is-active jrmc-vnc.service 2>/dev/null || true)"
  echo "native-rdp: $(systemctl is-active xrdp.service 2>/dev/null || true)"
}

case "${action}" in
  set)
    scale="${2:-}"
    if ! allowed_scale "${scale}"; then
      echo "Usage: jrmc-scale set {100|125|150|175|200}" >&2
      exit 1
    fi
    update_default JRMC_UI_SCALE "${scale}"
    source /etc/default/jrmc
    if restart_vnc_mode_if_active; then
      echo "JRMC UI scale set to ${scale}%."
      echo "VNC mode was restarted so the new framebuffer size takes effect immediately for noVNC and direct VNC."
    else
      apply_shared_display_now
      echo "JRMC UI scale set to ${scale}%."
    fi
    echo "Future VNC and native RDP sessions will use the new preset."
    if systemctl is-active --quiet xrdp.service || /usr/local/bin/jrmc-pidfile-active "${JRMC_RDP_PIDFILE}" >/dev/null 2>&1; then
      echo "Active RDP sessions receive updated DPI hints best-effort; reconnect if the client ignores them."
    fi
    echo "For the sharpest result, let noVNC fit the larger framebuffer and keep client-side scaling at 100% / 1:1 in TigerVNC or Remmina when using high JRMC scale presets."
    ;;
  status)
    print_status
    ;;
  apply-current)
    apply_shared_display_now
    echo "Reapplied JRMC scale hints to the shared display."
    ;;
  *)
    echo "Usage: jrmc-scale {set <100|125|150|175|200>|status|apply-current}" >&2
    exit 1
    ;;
esac
EOF
chmod +x /usr/local/bin/jrmc-scale

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

cat <<'EOF' >/usr/local/bin/jrmc-pidfile-active
#!/usr/bin/env bash
set -euo pipefail

pidfile="${1:-}"
if [[ -z "${pidfile}" || ! -s "${pidfile}" ]]; then
  exit 1
fi

pid="$(tr -d '[:space:]' <"${pidfile}")"
if [[ -z "${pid}" ]]; then
  rm -f "${pidfile}"
  exit 1
fi

if kill -0 "${pid}" >/dev/null 2>&1; then
  printf '%s\n' "${pid}"
  exit 0
fi

rm -f "${pidfile}"
exit 1
EOF
chmod +x /usr/local/bin/jrmc-pidfile-active

cat <<'EOF' >/usr/local/bin/jrmc-stop-rdp-session
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

stop_pidfile() {
  local pidfile="$1"
  local pid
  if ! pid="$(/usr/local/bin/jrmc-pidfile-active "${pidfile}" 2>/dev/null)"; then
    rm -f "${pidfile}"
    return 0
  fi

  kill -TERM "${pid}" >/dev/null 2>&1 || true
  for _i in $(seq 1 20); do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
  kill -KILL "${pid}" >/dev/null 2>&1 || true
  rm -f "${pidfile}"
}

stop_pidfile "${JRMC_RDP_PIDFILE}"
stop_pidfile "${JRMC_RDP_OPENBOX_PIDFILE}"
EOF
chmod +x /usr/local/bin/jrmc-stop-rdp-session

cat <<'EOF' >/usr/local/bin/jrmc-stop-shared-ui
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

systemctl stop jrmc-native-vnc.service jrmc-ui.service jrmc-websockify.service jrmc-vnc.service >/dev/null 2>&1 || true
rm -f "${JRMC_UI_PIDFILE}"
EOF
chmod +x /usr/local/bin/jrmc-stop-shared-ui

cat <<'EOF' >/usr/local/bin/jrmc-rdp-session-start
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

export HOME="${JRMC_HOME}"
export USER="${JRMC_USER}"
export DISPLAY="${DISPLAY:-:${JRMC_DISPLAY}}"
export XAUTHORITY="${XAUTHORITY:-${JRMC_HOME}/.Xauthority}"

eval "$(/usr/local/bin/jrmc-scale-profile exports)"

service_is_busy() {
  local state
  state="$(systemctl show -p ActiveState --value "$1" 2>/dev/null || true)"
  [[ "${state}" == "active" || "${state}" == "activating" || "${state}" == "reloading" ]]
}

if service_is_busy jrmc-ui.service || /usr/local/bin/jrmc-pidfile-active "${JRMC_UI_PIDFILE}" >/dev/null 2>&1; then
  echo "JRMC shared UI mode is already active. Stop noVNC/native VNC before launching native RDP." >&2
  exit 1
fi

if service_is_busy jrmc-mediaserver.service; then
  echo "JRMC Media Server mode is still active. Stop it before launching native RDP." >&2
  exit 1
fi

if /usr/local/bin/jrmc-pidfile-active "${JRMC_RDP_PIDFILE}" >/dev/null 2>&1; then
  echo "A native RDP JRMC session is already active." >&2
  exit 1
fi

for _i in $(seq 1 30); do
  xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1 && break
  sleep 0.5
done

cleanup() {
  rm -f "${JRMC_RDP_PIDFILE}" "${JRMC_RDP_OPENBOX_PIDFILE}"
  if [[ -n "${scale_watch_pid:-}" ]] && kill -0 "${scale_watch_pid}" >/dev/null 2>&1; then
    kill -TERM "${scale_watch_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${openbox_pid:-}" ]] && kill -0 "${openbox_pid}" >/dev/null 2>&1; then
    kill -TERM "${openbox_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

/usr/local/bin/jrmc-scale-profile apply-session >/dev/null 2>&1 || true
/usr/local/bin/jrmc-scale-watch >/dev/null 2>&1 &
scale_watch_pid=$!

nohup /usr/bin/openbox >/tmp/jrmc-openbox-rdp.log 2>&1 &
openbox_pid=$!
printf '%s\n' "${openbox_pid}" >"${JRMC_RDP_OPENBOX_PIDFILE}"
sleep 1

/usr/bin/mediacenter35 &
app_pid=$!
printf '%s\n' "${app_pid}" >"${JRMC_RDP_PIDFILE}"
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
export XAUTHORITY="${JRMC_HOME}/.Xauthority"

eval "$(/usr/local/bin/jrmc-scale-profile exports)"

service_is_busy() {
  local state
  state="$(systemctl show -p ActiveState --value "$1" 2>/dev/null || true)"
  [[ "${state}" == "active" || "${state}" == "activating" || "${state}" == "reloading" ]]
}

if service_is_busy xrdp.service || service_is_busy xrdp-sesman.service || /usr/local/bin/jrmc-pidfile-active "${JRMC_RDP_PIDFILE}" >/dev/null 2>&1; then
  echo "Native RDP owns the interactive JRMC session. Disable native RDP before launching the shared UI." >&2
  exit 1
fi

for _i in $(seq 1 30); do
  xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1 && break
  sleep 0.5
done

/usr/local/bin/jrmc-openbox-start

cleanup() {
  rm -f "${JRMC_UI_PIDFILE}"
  if [[ -n "${scale_watch_pid:-}" ]] && kill -0 "${scale_watch_pid}" >/dev/null 2>&1; then
    kill -TERM "${scale_watch_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

/usr/local/bin/jrmc-scale-profile apply-session >/dev/null 2>&1 || true
/usr/local/bin/jrmc-scale-watch >/dev/null 2>&1 &
scale_watch_pid=$!

/usr/bin/mediacenter35 &
app_pid=$!
printf '%s\n' "${app_pid}" >"${JRMC_UI_PIDFILE}"
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

cat <<'EOF' >/usr/local/bin/jrmc-native-vnc-clean
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

install -d -m 700 -o "${JRMC_USER}" -g "${JRMC_USER}" "${JRMC_HOME}/.config/tigervnc"
find "${JRMC_HOME}/.config/tigervnc" -maxdepth 1 \( -type l -o -type f \) -name "*:${JRMC_DISPLAY}.pid" -delete 2>/dev/null || true
rm -f "${JRMC_NATIVE_VNC_PIDFILE}"
EOF
chmod +x /usr/local/bin/jrmc-native-vnc-clean

cat <<'EOF' >/usr/local/bin/jrmc-native-vnc-start
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

export HOME="${JRMC_HOME}"
export USER="${JRMC_USER}"
export DISPLAY=":${JRMC_DISPLAY}"
export XAUTHORITY="${JRMC_HOME}/.Xauthority"

/usr/local/bin/jrmc-native-vnc-clean

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
  -pidfile "${JRMC_NATIVE_VNC_PIDFILE}"
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

cat <<'EOF' >/usr/local/bin/jrmc-native-vnc-stop
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

export DISPLAY=":${JRMC_DISPLAY}"

/usr/bin/x0vncserver -kill -display "${DISPLAY}" -rfbport "${JRMC_NATIVE_VNC_PORT}" >/dev/null 2>&1 || true
/usr/local/bin/jrmc-native-vnc-clean
EOF
chmod +x /usr/local/bin/jrmc-native-vnc-stop

cat <<'EOF' >/usr/local/bin/jrmc-sync-rdp-user
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

username="${1:-}"
password="${2:-}"

if [[ -z "${username}" || -z "${password}" ]]; then
  echo "Usage: jrmc-sync-rdp-user <username> <password>" >&2
  exit 1
fi

if [[ ! "${username}" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; then
  echo "Username must match [A-Za-z0-9._-] and be 3-32 chars." >&2
  exit 1
fi

service_uid="$(id -u "${JRMC_USER}")"
service_gid="$(id -g "${JRMC_USER}")"
current_rdp_user="${JRMC_NATIVE_RDP_USER:-${JRMC_USER}}"

if id -u "${username}" >/dev/null 2>&1; then
  existing_uid="$(id -u "${username}")"
  if [[ "${existing_uid}" != "${service_uid}" ]]; then
    echo "Username conflicts with an existing system account." >&2
    exit 1
  fi
fi

if [[ "${current_rdp_user}" != "${JRMC_USER}" ]] && [[ "${current_rdp_user}" != "${username}" ]] && id -u "${current_rdp_user}" >/dev/null 2>&1; then
  passwd -l "${current_rdp_user}" >/dev/null 2>&1 || true
fi

if [[ "${username}" != "${JRMC_USER}" ]]; then
  if ! id -u "${username}" >/dev/null 2>&1; then
    useradd -M -o -u "${service_uid}" -g "${service_gid}" -d "${JRMC_HOME}" -s /bin/bash "${username}"
  fi
  usermod -o -u "${service_uid}" -g "${service_gid}" -d "${JRMC_HOME}" -s /bin/bash "${username}" >/dev/null 2>&1 || true
fi

printf '%s:%s\n' "${JRMC_USER}" "${password}" | chpasswd
if [[ "${username}" != "${JRMC_USER}" ]]; then
  printf '%s:%s\n' "${username}" "${password}" | chpasswd
fi

python3 - "$username" <<'PY'
import sys
from pathlib import Path

path = Path('/etc/default/jrmc')
value = sys.argv[1]
lines = path.read_text().splitlines()
new_lines = []
found = False
for line in lines:
    if line.startswith('JRMC_NATIVE_RDP_USER='):
        new_lines.append(f'JRMC_NATIVE_RDP_USER="{value}"')
        found = True
    else:
        new_lines.append(line)
if not found:
    new_lines.append(f'JRMC_NATIVE_RDP_USER="{value}"')
path.write_text("\n".join(new_lines) + "\n")
PY
EOF
chmod +x /usr/local/bin/jrmc-sync-rdp-user

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

/usr/local/bin/jrmc-sync-rdp-user "${username}" "${password}"
source /etc/default/jrmc

htpasswd -b -c -5 "${JRMC_WEB_HTPASSWD}" "${username}" "${password}" >/dev/null 2>&1
htpasswd -b -c -5 "${JRMC_VNC_HTPASSWD}" "${username}" "${password}" >/dev/null 2>&1
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
Modes: choose Media Server, VNC, or RDP from Dashboard or jrmc-mode.
VNC mode: browser noVNC and direct VNC on port ${JRMC_NATIVE_VNC_PORT} run together against the same JRMC session using the Dashboard username and password.
RDP mode: native RDP on port ${JRMC_NATIVE_RDP_PORT} for Remmina using the same username and password as Dashboard.
UI Scale: set 100%-200% presets from Dashboard or jrmc-scale; active sessions update best-effort.
CREDS

systemctl reload nginx
EOF
chmod +x /usr/local/bin/jrmc-set-web-credentials

cat <<'EOF' >/usr/local/bin/jrmc-mode
#!/usr/bin/env bash
set -euo pipefail

source /etc/default/jrmc

mode="${1:-status}"

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

persist_mode() {
  local new_mode="$1"
  update_default JRMC_MODE "${new_mode}"
  case "${new_mode}" in
    mediaserver)
      update_default JRMC_NATIVE_VNC_ENABLED 0
      update_default JRMC_NATIVE_RDP_ENABLED 0
      ;;
    vnc)
      update_default JRMC_NATIVE_VNC_ENABLED 1
      update_default JRMC_NATIVE_RDP_ENABLED 0
      ;;
    rdp)
      update_default JRMC_NATIVE_VNC_ENABLED 0
      update_default JRMC_NATIVE_RDP_ENABLED 1
      ;;
  esac
}

current_mode() {
  if systemctl is-active --quiet xrdp.service || systemctl is-active --quiet xrdp-sesman.service || /usr/local/bin/jrmc-pidfile-active "${JRMC_RDP_PIDFILE}" >/dev/null 2>&1; then
    echo "rdp"
  elif systemctl is-active --quiet jrmc-ui.service || systemctl is-active --quiet jrmc-websockify.service || systemctl is-active --quiet jrmc-native-vnc.service; then
    echo "vnc"
  elif systemctl is-active --quiet jrmc-mediaserver.service; then
    echo "mediaserver"
  else
    echo "stopped"
  fi
}

stop_rdp_runtime() {
  systemctl stop xrdp.service xrdp-sesman.service >/dev/null 2>&1 || true
  /usr/local/bin/jrmc-stop-rdp-session
}

stop_vnc_runtime() {
  systemctl stop jrmc-native-vnc.service jrmc-ui.service jrmc-websockify.service jrmc-vnc.service >/dev/null 2>&1 || true
  rm -f "${JRMC_UI_PIDFILE}"
}

case "${mode}" in
  ui|vnc)
    stop_rdp_runtime
    systemctl stop jrmc-mediaserver.service || true
    systemctl restart jrmc-vnc.service
    systemctl restart jrmc-websockify.service
    systemctl restart jrmc-ui.service
    systemctl restart jrmc-native-vnc.service
    persist_mode vnc
    echo "JRMC VNC mode started. Browser noVNC and direct VNC now share the same writable JRMC session."
    ;;
  mediaserver|server)
    stop_rdp_runtime
    systemctl stop jrmc-native-vnc.service jrmc-ui.service jrmc-websockify.service || true
    systemctl restart jrmc-vnc.service
    systemctl restart jrmc-mediaserver.service
    persist_mode mediaserver
    echo "JRMC Media Server mode started. Interactive VNC and RDP transports were stopped."
    ;;
  rdp)
    systemctl stop jrmc-mediaserver.service >/dev/null 2>&1 || true
    stop_vnc_runtime
    /usr/local/bin/jrmc-stop-rdp-session
    systemctl enable --now xrdp-sesman.service xrdp.service
    persist_mode rdp
    echo "JRMC RDP mode started. VNC transports were stopped so RDP owns the writable JRMC session."
    ;;
  stop-ui)
    stop_vnc_runtime
    persist_mode mediaserver
    echo "JRMC VNC mode stopped. Choose another mode to continue using JRMC."
    ;;
  stop-server)
    systemctl stop jrmc-mediaserver.service || true
    systemctl stop jrmc-vnc.service || true
    echo "JRMC Media Server mode stopped."
    ;;
  status)
    active_mode="$(current_mode)"
    echo "desired-mode: ${JRMC_MODE:-mediaserver}"
    echo "active-mode: ${active_mode}"
    echo "jrmc-mediaserver: $(systemctl is-active jrmc-mediaserver.service 2>/dev/null || true)"
    echo "jrmc-vnc: $(systemctl is-active jrmc-vnc.service 2>/dev/null || true)"
    echo "jrmc-websockify: $(systemctl is-active jrmc-websockify.service 2>/dev/null || true)"
    echo "jrmc-ui: $(systemctl is-active jrmc-ui.service 2>/dev/null || true)"
    echo "jrmc-native-vnc: $(systemctl is-active jrmc-native-vnc.service 2>/dev/null || true)"
    echo "xrdp: $(systemctl is-active xrdp.service 2>/dev/null || true)"
    echo "ui-scale: ${JRMC_UI_SCALE:-100}%"
    if [[ "${active_mode}" == "vnc" ]]; then
      echo "novnc: https://$(hostname -I | awk '{print $1}'):${JRMC_WEB_PORT}/novnc/vnc.html?autoconnect=1&resize=scale&path=/websockify"
      echo "direct-vnc: $(hostname -I | awk '{print $1}'):${JRMC_NATIVE_VNC_PORT}"
    elif [[ "${active_mode}" == "rdp" ]]; then
      echo "rdp: $(hostname -I | awk '{print $1}'):${JRMC_NATIVE_RDP_PORT}"
      echo "rdp-user: ${JRMC_NATIVE_RDP_USER}"
    fi
    ;;
  *)
    echo "Usage: jrmc-mode {vnc|ui|rdp|mediaserver|server|stop-ui|stop-server|status}" >&2
    exit 1
    ;;
esac
EOF
chmod +x /usr/local/bin/jrmc-mode

cat <<'EOF' >/usr/local/bin/jrmc-direct-vnc
#!/usr/bin/env bash
set -euo pipefail

action="${1:-status}"

case "${action}" in
  enable)
    exec /usr/local/bin/jrmc-mode vnc
    ;;
  disable)
    exec /usr/local/bin/jrmc-mode mediaserver
    ;;
  status)
    echo "VNC mode bundles browser noVNC and direct VNC together."
    /usr/local/bin/jrmc-mode status
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

action="${1:-status}"

case "${action}" in
  enable)
    exec /usr/local/bin/jrmc-mode rdp
    ;;
  disable)
    exec /usr/local/bin/jrmc-mode mediaserver
    ;;
  status)
    echo "RDP mode is one of the three primary JRMC runtime modes."
    /usr/local/bin/jrmc-mode status
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

systemctl stop jrmc-ui.service jrmc-websockify.service jrmc-vnc.service jrmc-mediaserver.service xrdp.service xrdp-sesman.service || true
/usr/local/bin/jrmc-stop-rdp-session
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
  "<p>The container starts in Media Server mode. Use Dashboard to switch between Media Server, VNC, and RDP as needed.</p>"
    "</body></html>"
)
EOF
chmod +x ${CGI_BIN}/jrmc-setup.py

cat <<'EOF' >${CGI_BIN}/jrmc-control.py
#!/usr/bin/env python3
import html
import os
import subprocess
import sys
from urllib.parse import parse_qs


def read_params() -> dict[str, list[str]]:
  params = parse_qs(os.environ.get("QUERY_STRING", ""), keep_blank_values=True)
  if os.environ.get("REQUEST_METHOD", "GET").upper() == "POST":
    length = int(os.environ.get("CONTENT_LENGTH", "0") or "0")
    body = parse_qs(sys.stdin.read(length), keep_blank_values=True)
    params.update(body)
  return params


params = read_params()
action = params.get("action", [""])[0]
scale = params.get("ui_scale", [""])[0].strip()

mapping = {
  "switch-vnc": ["sudo", "/usr/local/bin/jrmc-mode", "vnc"],
  "switch-rdp": ["sudo", "/usr/local/bin/jrmc-mode", "rdp"],
  "switch-mediaserver": ["sudo", "/usr/local/bin/jrmc-mode", "mediaserver"],
  "mode-status": ["sudo", "/usr/local/bin/jrmc-mode", "status"],
  "start-ui": ["sudo", "/usr/local/bin/jrmc-mode", "vnc"],
  "stop-ui": ["sudo", "/usr/local/bin/jrmc-mode", "mediaserver"],
  "start-server": ["sudo", "/usr/local/bin/jrmc-mode", "mediaserver"],
  "stop-server": ["sudo", "/usr/local/bin/jrmc-mode", "mediaserver"],
  "enable-direct-rdp": ["sudo", "/usr/local/bin/jrmc-mode", "rdp"],
  "disable-direct-rdp": ["sudo", "/usr/local/bin/jrmc-mode", "mediaserver"],
  "direct-rdp-status": ["sudo", "/usr/local/bin/jrmc-mode", "status"],
  "enable-direct-vnc": ["sudo", "/usr/local/bin/jrmc-mode", "vnc"],
  "disable-direct-vnc": ["sudo", "/usr/local/bin/jrmc-mode", "mediaserver"],
  "direct-vnc-status": ["sudo", "/usr/local/bin/jrmc-mode", "status"],
    "ui-scale-status": ["sudo", "/usr/local/bin/jrmc-scale", "status"],
}

print("Content-Type: text/html")
print()

if action == "set-ui-scale":
  if scale not in {"100", "125", "150", "175", "200"}:
    print("<html><body><h1>Invalid scale preset</h1><p><a href='/dashboard/'>Back</a></p></body></html>")
    raise SystemExit(0)
  command = ["sudo", "/usr/local/bin/jrmc-scale", "set", scale]
elif action in mapping:
  command = mapping[action]
else:
  print("<html><body><h1>Invalid action</h1><p><a href='/dashboard/'>Back</a></p></body></html>")
  raise SystemExit(0)

result = subprocess.run(command, capture_output=True, text=True, check=False)
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
    <p>After setup, sign in at <a href="/dashboard/">Dashboard</a>, then choose Media Server, VNC, or RDP mode.</p>
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
    a,button{display:inline-block;padding:.9rem 1.2rem;border-radius:8px;background:#2563eb;color:white;text-decoration:none;border:0;font-weight:600;cursor:pointer}
    .alt{background:#475569}
    .stack{display:grid;gap:.75rem}
    .scale-form{display:grid;gap:.75rem;max-width:420px}
    label{font-weight:600}
    select{width:100%;padding:.8rem;border-radius:8px;border:1px solid #475569;background:#020617;color:#e2e8f0}
    code{background:#020617;padding:.15rem .35rem;border-radius:4px}
  </style>
</head>
<body>
  <div class="card">
    <h1>JRiver Media Center Dashboard</h1>
    <p>Choose one active runtime mode at a time: <strong>Media Server</strong>, <strong>VNC</strong>, or <strong>RDP</strong>.</p>
    <div class="actions">
      <a href="/cgi-bin/jrmc-control.py?action=switch-vnc">Switch to VNC</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=switch-rdp">Switch to RDP</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=switch-mediaserver">Switch to Media Server</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=mode-status">Mode Status</a>
    </div>
  </div>
  <div class="card">
    <h2>VNC Mode</h2>
    <p>VNC mode starts one shared JRMC desktop and exposes it through both browser noVNC and direct VNC automatically.</p>
    <div class="actions">
      <a href="/novnc/vnc.html?autoconnect=1&resize=scale&path=/websockify">Open noVNC</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=switch-vnc">Start VNC Mode</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=mode-status">Mode Status</a>
    </div>
    <p>Browser noVNC uses the shared VNC framebuffer through the web dashboard. Direct VNC listens on port <code>5902</code>, uses <code>TLSPlain</code>, and signs in with the same Dashboard username and password.</p>
    <p>Both VNC transports always point to the same JRMC session. Switching to <strong>RDP</strong> or <strong>Media Server</strong> cleanly tears down VNC mode first.</p>
  </div>
  <div class="card">
    <h2>RDP Mode</h2>
    <p>RDP mode starts a separate xrdp session on port <code>3389</code> for Remmina and other RDP clients using the same Dashboard username and password.</p>
    <p>Switching to RDP stops VNC and Media Server so JRiver keeps one writable library owner at a time.</p>
  </div>
  <div class="card">
    <h2>UI Scale</h2>
    <div class="stack">
      <form class="scale-form" method="post" action="/cgi-bin/jrmc-control.py">
        <input type="hidden" name="action" value="set-ui-scale">
        <label for="ui_scale">JRMC UI scale preset</label>
        <select id="ui_scale" name="ui_scale">
          <option value="100" selected>100% — Default sharpness</option>
          <option value="125">125% — Slightly larger controls</option>
          <option value="150">150% — Comfortable HiDPI preset</option>
          <option value="175">175% — Large desktop controls</option>
          <option value="200">200% — Maximum built-in scale</option>
        </select>
        <button type="submit">Apply UI Scale</button>
      </form>
      <div class="actions">
        <a class="alt" href="/cgi-bin/jrmc-control.py?action=ui-scale-status">UI Scale Status</a>
      </div>
    </div>
    <p>Scale presets persist for future VNC and RDP sessions. In VNC mode, larger presets request a larger server framebuffer so noVNC can scale it back down cleanly in the browser.</p>
    <p>For the sharpest result, let noVNC fit the view automatically and prefer 100% / 1:1 client-side scaling in TigerVNC and Remmina when using a larger JRMC scale preset.</p>
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
python3 - <<'PY'
from pathlib import Path

path = Path('/etc/xrdp/xrdp.ini')
text = path.read_text()
old = "[Xorg]\nname=Xorg\nlib=libxup.so\nusername=ask\npassword=ask\nport=3389\ncode=20\n"
new = "[Xorg]\nname=Xorg\nlib=libxup.so\nusername=ask\npassword=ask\nport=-1\ncode=20\n"

if old in text:
  text = text.replace(old, new, 1)

path.write_text(text)
PY
systemctl disable --now xrdp.service xrdp-sesman.service >/dev/null 2>&1 || true

cat <<'EOF' >/etc/sudoers.d/jrmc-web
www-data ALL=(root) NOPASSWD: /usr/local/bin/jrmc-mode, /usr/local/bin/jrmc-direct-rdp, /usr/local/bin/jrmc-direct-vnc, /usr/local/bin/jrmc-scale, /usr/local/bin/jrmc-set-web-credentials
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
Type=forking
PIDFile=${CONFIG_DIR}/native-vnc.pid
ExecStartPre=/usr/local/bin/jrmc-native-vnc-clean
ExecStart=/usr/local/bin/jrmc-native-vnc-start
ExecStop=/usr/local/bin/jrmc-native-vnc-stop
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
echo "VNC mode:             Browser noVNC plus direct VNC on port 5902 at the same time"
echo "UI Scale:             Presets 100/125/150/175/200 via Dashboard or jrmc-scale"
echo "RDP mode:             Port 3389 for Remmina using the same Dashboard username; switching modes tears down the others first"
echo

PS3="Select an option: "
select opt in \
  "Set web credentials" \
  "Switch to VNC mode" \
  "Switch to RDP mode" \
  "Switch to Media Server mode" \
  "Show current mode status" \
  "Set UI scale preset" \
  "Show UI scale status" \
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
  "Switch to VNC mode")
    /usr/local/bin/jrmc-mode vnc
    ;;
  "Switch to RDP mode")
    /usr/local/bin/jrmc-mode rdp
    ;;
  "Switch to Media Server mode")
    /usr/local/bin/jrmc-mode mediaserver
    ;;
  "Show current mode status")
    /usr/local/bin/jrmc-mode status
    ;;
  "Set UI scale preset")
    read -r -p "Choose UI scale preset (100, 125, 150, 175, 200): " scale
    /usr/local/bin/jrmc-scale set "$scale"
    ;;
  "Show UI scale status")
    /usr/local/bin/jrmc-scale status
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
