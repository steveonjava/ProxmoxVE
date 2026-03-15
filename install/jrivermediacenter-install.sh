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
JRMC_VNC_PORT=5900
JRMC_NATIVE_RDP_PORT=3389
JRMC_WEBSOCKIFY_PORT=6080
JRMC_WEB_PORT=5800

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_custom "ℹ️" "${GN}" "If GPU passthrough is enabled, JRiver will install guest-side acceleration libraries and validation tools"
setup_hwaccel

if [[ "${ENABLE_GPU:-no}" == "yes" ]]; then
  msg_info "Installing GPU Validation Tools"
  $STD apt install -y ffmpeg pciutils >/dev/null 2>&1
  msg_ok "Installed GPU Validation Tools"
fi

msg_info "Installing Dependencies"
$STD apt install -y \
  apache2-utils \
  alsa-utils \
  dbus-x11 \
  fcgiwrap \
  libasound2-plugins \
  nginx \
  novnc \
  openbox \
  pulseaudio-utils \
  python3 \
  ssl-cert \
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
if [[ "${ENABLE_GPU:-no}" == "yes" ]]; then
  for gpu_group in render video; do
    if getent group "${gpu_group}" >/dev/null 2>&1; then
      usermod -aG "${gpu_group}" "${APP_USER}" >/dev/null 2>&1 || true
    fi
  done
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
JRMC_NATIVE_RDP_PORT="${JRMC_NATIVE_RDP_PORT}"
JRMC_WEBSOCKIFY_PORT="${JRMC_WEBSOCKIFY_PORT}"
JRMC_WEB_PORT="${JRMC_WEB_PORT}"
JRMC_WIDTH="1440"
JRMC_HEIGHT="900"
JRMC_UI_SCALE="100"
JRMC_MODE="mediaserver"
JRMC_GPU_ENABLED="${ENABLE_GPU:-no}"
JRMC_GPU_SELECTED_TYPE="${GPU_TYPE:-}"
JRMC_REMOTE_AUDIO_ENABLED="0"
JRMC_REMOTE_AUDIO_HOST=""
JRMC_REMOTE_AUDIO_PORT="4713"
JRMC_REMOTE_AUDIO_SINK=""
JRMC_WEB_HTPASSWD="/etc/nginx/jrmc.htpasswd"
JRMC_VNC_PASSWD_FILE="${CONFIG_DIR}/vncpasswd"
JRMC_BOOTSTRAP_FILE="${CONFIG_DIR}/bootstrap-complete"
JRMC_NATIVE_RDP_ENABLED="0"
JRMC_NATIVE_RDP_USER="${APP_USER}"
JRMC_RUNTIME_DIR="${RUNTIME_DIR}"
JRMC_UI_PIDFILE="${RUNTIME_DIR}/ui.pid"
JRMC_RDP_PIDFILE="${RUNTIME_DIR}/rdp.pid"
JRMC_RDP_OPENBOX_PIDFILE="${RUNTIME_DIR}/rdp-openbox.pid"
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
printf '%s\n' "${tmp_password}" | tigervncpasswd -f >"${CONFIG_DIR}/vncpasswd"
chown root:www-data /etc/nginx/jrmc.htpasswd
chmod 0640 /etc/nginx/jrmc.htpasswd
chown "${APP_USER}:${APP_USER}" "${CONFIG_DIR}/vncpasswd"
chmod 0600 "${CONFIG_DIR}/vncpasswd"

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
  -SecurityTypes TLSVnc,VncAuth
  -desktop "JRiver Media Center"
  -auth "${HOME}/.Xauthority"
  -PasswordFile "${JRMC_VNC_PASSWD_FILE}"
  -IdleTimeout 0
  -MaxConnectionTime 0
  -MaxDisconnectionTime 0
  -MaxIdleTime 0
  -AcceptSetDesktopSize=1
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

cat <<'EOF' >/usr/local/bin/jrmc-app-scale
#!/usr/bin/env bash
set -euo pipefail

source /etc/default/jrmc

target="${1:-status}"
settings_file="${JRMC_HOME}/.jriver/Media Center 35/Settings/User Settings.ini"

mapped_scale() {
  case "${JRMC_UI_SCALE:-100}" in
    100) printf '1\n' ;;
    125) printf '1.25\n' ;;
    150) printf '1.5\n' ;;
    175) printf '1.75\n' ;;
    200) printf '2\n' ;;
    *) printf '1\n' ;;
  esac
}

target_scale() {
  case "${1:-}" in
    vnc) printf '1\n' ;;
    rdp) mapped_scale ;;
    *) return 1 ;;
  esac
}

write_setting() {
  local value="$1"
  python3 - "$settings_file" "$value" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
value = sys.argv[2]

if path.exists():
    lines = path.read_text().splitlines()
else:
    lines = []

new_lines = []
found = False
current_section = ""
inserted_in_properties = False

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if current_section == "[Properties]" and not found and not inserted_in_properties:
            new_lines.append(f'Standard View - Size="{value}"')
            inserted_in_properties = True
        current_section = stripped

    if line.startswith("Standard View - Size="):
        new_lines.append(f'Standard View - Size="{value}"')
        found = True
    else:
        new_lines.append(line)

if not found:
    if not lines:
        new_lines = ["[Properties]", f'Standard View - Size="{value}"']
    elif current_section == "[Properties]" and not inserted_in_properties:
        new_lines.append(f'Standard View - Size="{value}"')
    else:
        if new_lines and new_lines[-1] != "":
            new_lines.append("")
        new_lines.append("[Properties]")
        new_lines.append(f'Standard View - Size="{value}"')

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(new_lines) + "\n")
PY
}

case "${target}" in
  vnc|rdp)
    scale_value="$(target_scale "${target}")"
    write_setting "${scale_value}"
    printf '%s\n' "${scale_value}"
    ;;
  status)
    if [[ -f "${settings_file}" ]]; then
      grep -m1 '^Standard View - Size=' "${settings_file}" | cut -d'=' -f2- || true
    fi
    ;;
  *)
    echo "Usage: jrmc-app-scale {vnc|rdp|status}" >&2
    exit 1
    ;;
esac
EOF
chmod +x /usr/local/bin/jrmc-app-scale

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
  echo "jriver-app-scale: $(/usr/local/bin/jrmc-app-scale status 2>/dev/null || true)"
  echo "shared-ui: $(systemctl is-active jrmc-ui.service 2>/dev/null || true)"
  echo "shared-vnc-backend: $(systemctl is-active jrmc-vnc.service 2>/dev/null || true)"
  echo "native-rdp: $(systemctl is-active xrdp.service 2>/dev/null || true)"
}

case "${action}" in
  set)
    scale="${2:-}"
    active_mode=""
    if ! allowed_scale "${scale}"; then
      echo "Usage: jrmc-scale set {100|125|150|175|200}" >&2
      exit 1
    fi
    update_default JRMC_UI_SCALE "${scale}"
    source /etc/default/jrmc
    active_mode="$(/usr/local/bin/jrmc-mode status 2>/dev/null | awk -F': ' '/^active-mode:/ {print $2; exit}')"
    if restart_vnc_mode_if_active; then
      echo "JRMC UI scale set to ${scale}%."
      echo "VNC mode was restarted so the new framebuffer size takes effect immediately for noVNC and direct VNC."
    else
      if [[ "${active_mode}" == "rdp" ]]; then
        /usr/local/bin/jrmc-app-scale rdp >/dev/null 2>&1 || true
      fi
      apply_shared_display_now
      echo "JRMC UI scale set to ${scale}%."
    fi
    echo "Future VNC sessions keep JRiver internal scale at 1 while shared-display scaling follows the preset. Future RDP sessions map the preset into JRiver's own Standard View size setting."
    if systemctl is-active --quiet xrdp.service || /usr/local/bin/jrmc-pidfile-active "${JRMC_RDP_PIDFILE}" >/dev/null 2>&1; then
      echo "If an RDP JRiver session is already running, reconnect so the app relaunches with the updated JRiver internal scale."
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

cat <<'EOF' >/usr/local/bin/jrmc-remote-audio
#!/usr/bin/env bash
set -euo pipefail

source /etc/default/jrmc

action="${1:-status}"
settings_file="${JRMC_HOME}/.jriver/Media Center 35/Settings/User Settings.ini"

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

write_client_conf() {
  install -d -m 700 -o "${JRMC_USER}" -g "${JRMC_USER}" "${JRMC_HOME}/.config/pulse"

  if [[ "${JRMC_REMOTE_AUDIO_ENABLED:-0}" == "1" && -n "${JRMC_REMOTE_AUDIO_HOST:-}" ]]; then
    cat <<CONF >"${JRMC_HOME}/.config/pulse/client.conf"
default-server = tcp:${JRMC_REMOTE_AUDIO_HOST}:${JRMC_REMOTE_AUDIO_PORT:-4713}
autospawn = no
enable-shm = false
CONF
  else
    rm -f "${JRMC_HOME}/.config/pulse/client.conf"
  fi

  chown "${JRMC_USER}:${JRMC_USER}" "${JRMC_HOME}/.config/pulse" >/dev/null 2>&1 || true
  [[ -f "${JRMC_HOME}/.config/pulse/client.conf" ]] && chown "${JRMC_USER}:${JRMC_USER}" "${JRMC_HOME}/.config/pulse/client.conf"
}

write_jriver_output() {
  local descriptor="$1"
  python3 - "$settings_file" "$descriptor" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
descriptor = sys.argv[2]
section = r"[Zones\\0\\ALSA]"
updates = {
    "ALSA Output Format": 'i:"0"',
    "Buffer Time": 'i:"400000"',
    "Mixer Device": 'i:"-1"',
    "Output Descriptor": f'"{descriptor}"',
    "Output DSD": 'i:"0"',
    "Period Time": 'i:"100000"',
}

if path.exists():
    lines = path.read_text().splitlines()
else:
    lines = []

new_lines = []
current_section = None
in_target = False
seen = set()

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if in_target:
            for key, value in updates.items():
                if key not in seen:
                    new_lines.append(f"{key}={value}")
            seen.clear()
        current_section = stripped
        in_target = current_section == section
        new_lines.append(line)
        continue

    if in_target and "=" in line:
        key, _value = line.split("=", 1)
        if key in updates:
            new_lines.append(f"{key}={updates[key]}")
            seen.add(key)
            continue

    new_lines.append(line)

if in_target:
    for key, value in updates.items():
        if key not in seen:
            new_lines.append(f"{key}={value}")
elif not lines:
    new_lines = [section] + [f"{key}={value}" for key, value in updates.items()]
else:
    if new_lines and new_lines[-1] != "":
        new_lines.append("")
    new_lines.append(section)
    new_lines.extend(f"{key}={value}" for key, value in updates.items())

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(new_lines) + "\n")
PY
  chown "${JRMC_USER}:${JRMC_USER}" "${settings_file}" >/dev/null 2>&1 || true
}

sync_jriver_output() {
  if [[ "${JRMC_REMOTE_AUDIO_ENABLED:-0}" == "1" && -n "${JRMC_REMOTE_AUDIO_HOST:-}" ]]; then
    write_jriver_output "pulse"
  else
    write_jriver_output "Default"
  fi
}

jriver_output_status() {
  if [[ -f "${settings_file}" ]]; then
    python3 - "${settings_file}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
section = r"[Zones\\0\\ALSA]"
in_section = False

for raw_line in path.read_text().splitlines():
    line = raw_line.strip()
    if line.startswith("[") and line.endswith("]"):
        if in_section:
            break
        in_section = line == section
        continue

    if in_section and line.startswith("Output Descriptor="):
        print(line.split("=", 1)[1].strip().strip('"'))
        break
PY
  fi
}

emit_env() {
  if [[ "${JRMC_REMOTE_AUDIO_ENABLED:-0}" == "1" && -n "${JRMC_REMOTE_AUDIO_HOST:-}" ]]; then
    printf 'export PULSE_SERVER=%q\n' "tcp:${JRMC_REMOTE_AUDIO_HOST}:${JRMC_REMOTE_AUDIO_PORT:-4713}"
    if [[ -n "${JRMC_REMOTE_AUDIO_SINK:-}" ]]; then
      printf 'export PULSE_SINK=%q\n' "${JRMC_REMOTE_AUDIO_SINK}"
    fi
  fi
}

print_status() {
  echo "remote-audio-enabled: ${JRMC_REMOTE_AUDIO_ENABLED:-0}"
  echo "remote-audio-host: ${JRMC_REMOTE_AUDIO_HOST:-}"
  echo "remote-audio-port: ${JRMC_REMOTE_AUDIO_PORT:-4713}"
  echo "remote-audio-sink: ${JRMC_REMOTE_AUDIO_SINK:-}"
  echo "jriver-output-descriptor: $(jriver_output_status)"
  if [[ "${JRMC_REMOTE_AUDIO_ENABLED:-0}" == "1" && -n "${JRMC_REMOTE_AUDIO_HOST:-}" ]]; then
    echo "pulse-server: tcp:${JRMC_REMOTE_AUDIO_HOST}:${JRMC_REMOTE_AUDIO_PORT:-4713}"
  else
    echo "pulse-server: disabled"
  fi
}

case "${action}" in
  enable)
    host="${2:-}"
    port="${3:-4713}"
    sink="${4:-}"
    if [[ -z "${host}" ]]; then
      echo "Usage: jrmc-remote-audio enable <host> [port] [sink]" >&2
      exit 1
    fi
    if ! [[ "${port}" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
      echo "Port must be between 1 and 65535." >&2
      exit 1
    fi
    update_default JRMC_REMOTE_AUDIO_ENABLED 1
    update_default JRMC_REMOTE_AUDIO_HOST "${host}"
    update_default JRMC_REMOTE_AUDIO_PORT "${port}"
    update_default JRMC_REMOTE_AUDIO_SINK "${sink}"
    source /etc/default/jrmc
    write_client_conf
    sync_jriver_output
    echo "Remote audio enabled: tcp:${JRMC_REMOTE_AUDIO_HOST}:${JRMC_REMOTE_AUDIO_PORT}"
    if [[ -n "${JRMC_REMOTE_AUDIO_SINK:-}" ]]; then
      echo "Preferred sink: ${JRMC_REMOTE_AUDIO_SINK}"
    fi
    echo "Restart the active JRMC mode so the player reconnects with the new Pulse endpoint."
    ;;
  disable)
    update_default JRMC_REMOTE_AUDIO_ENABLED 0
    source /etc/default/jrmc
    write_client_conf
    sync_jriver_output
    echo "Remote audio disabled."
    ;;
  emit-env)
    emit_env
    ;;
  sync-jriver-output)
    sync_jriver_output
    ;;
  status)
    print_status
    ;;
  *)
    echo "Usage: jrmc-remote-audio {enable <host> [port] [sink]|disable|status|emit-env|sync-jriver-output}" >&2
    exit 1
    ;;
esac
EOF
chmod +x /usr/local/bin/jrmc-remote-audio

cat <<'EOF' >/usr/local/bin/jrmc-gpu-status
#!/usr/bin/env bash
set -euo pipefail

source /etc/default/jrmc

join_lines() {
  awk 'BEGIN { first = 1 } { if (!first) printf ","; printf "%s", $0; first = 0 } END { if (first) printf "" }'
}

list_glob_paths() {
  local pattern path
  for pattern in "$@"; do
    for path in ${pattern}; do
      [[ -e "${path}" ]] || continue
      printf '%s\n' "${path}"
    done
  done
}

first_render_node() {
  list_glob_paths /dev/dri/renderD* | sort | head -n1
}

compact_dri_nodes() {
  list_glob_paths /dev/dri/* | xargs -r -n1 basename | sort | join_lines
}

compact_nvidia_nodes() {
  list_glob_paths /dev/nvidia* /dev/nvidia-caps/* | xargs -r -n1 basename | sort | join_lines
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

service_user_access() {
  local target="$1"
  local mode="$2"
  if runuser -u "${JRMC_USER}" -- test "-${mode}" "${target}"; then
    echo yes
  else
    echo no
  fi
}

safe_probe() {
  local label="$1"
  shift
  local output
  if output=$(timeout 20 "$@" 2>&1); then
    output=$(printf '%s\n' "$output" | sed '/^$/d' | head -n1)
    if [[ -n "$output" ]]; then
      printf '%s: ok (%s)\n' "$label" "$output"
    else
      printf '%s: ok\n' "$label"
    fi
  else
    output=$(printf '%s\n' "${output:-}" | sed '/^$/d' | head -n1)
    if [[ -n "$output" ]]; then
      printf '%s: failed (%s)\n' "$label" "$output"
    else
      printf '%s: failed\n' "$label"
    fi
  fi
}

render_node="$(first_render_node || true)"
lspci_summary="unavailable"
ffmpeg_hwaccels="unavailable"
ffmpeg_encoders="unavailable"

if have_command lspci; then
  lspci_summary="$(lspci -nn | grep -Ei 'VGA|3D|Display' | join_lines)"
  [[ -z "$lspci_summary" ]] && lspci_summary="none-detected"
fi

if have_command ffmpeg; then
  ffmpeg_hwaccels="$(ffmpeg -hide_banner -hwaccels 2>/dev/null | awk 'NR > 1 {print $1}' | join_lines)"
  ffmpeg_encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null | awk '/_vaapi|_nvenc|_qsv/ {print $2}' | sort -u | join_lines)"
  [[ -z "$ffmpeg_hwaccels" ]] && ffmpeg_hwaccels="none"
  [[ -z "$ffmpeg_encoders" ]] && ffmpeg_encoders="none"
fi

echo "gpu-enabled: ${JRMC_GPU_ENABLED:-no}"
echo "selected-gpu-type: ${JRMC_GPU_SELECTED_TYPE:-auto}"
echo "service-user: ${JRMC_USER}"
echo "service-user-groups: $(id -nG "${JRMC_USER}" 2>/dev/null | tr ' ' ',')"
echo "render-group: $(getent group render | cut -d: -f1,3,4 2>/dev/null || echo unavailable)"
echo "video-group: $(getent group video | cut -d: -f1,3,4 2>/dev/null || echo unavailable)"
echo "lspci-gpus: ${lspci_summary}"
echo "dri-render-node: ${render_node:-none}"
echo "dri-nodes: $(compact_dri_nodes || true)"
echo "nvidia-nodes: $(compact_nvidia_nodes || true)"
if [[ -n "${render_node:-}" ]]; then
  echo "service-user-render-read: $(service_user_access "${render_node}" r)"
  echo "service-user-render-write: $(service_user_access "${render_node}" w)"
else
  echo "service-user-render-read: unavailable"
  echo "service-user-render-write: unavailable"
fi
echo "ffmpeg-present: $(have_command ffmpeg && echo yes || echo no)"
echo "ffmpeg-hwaccels: ${ffmpeg_hwaccels}"
echo "ffmpeg-hw-encoders: ${ffmpeg_encoders}"

if have_command vainfo && [[ -n "${render_node:-}" ]]; then
  safe_probe "vainfo" vainfo --display drm --device "${render_node}"
else
  echo "vainfo: unavailable"
fi

if have_command nvidia-smi; then
  safe_probe "nvidia-smi" nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
else
  echo "nvidia-smi: unavailable"
fi
EOF
chmod +x /usr/local/bin/jrmc-gpu-status

cat <<'EOF' >/usr/local/bin/jrmc-gpu-test
#!/usr/bin/env bash
set -euo pipefail

source /etc/default/jrmc

render_node=""
for candidate in /dev/dri/renderD*; do
  [[ -e "${candidate}" ]] || continue
  render_node="${candidate}"
  break
done

has_nvidia_nodes=no
for candidate in /dev/nvidiactl /dev/nvidia0 /dev/nvidia-uvm /dev/nvidia-caps/*; do
  [[ -e "${candidate}" ]] || continue
  has_nvidia_nodes=yes
  break
done

failures=0

pass() {
  printf '[PASS] %s\n' "$1"
}

skip() {
  printf '[SKIP] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1"
  failures=$((failures + 1))
}

show_output() {
  printf '%s\n' "$1" | sed '/^$/d' | head -n12
}

run_probe() {
  local label="$1"
  shift
  local output
  if output=$(timeout 30 "$@" 2>&1); then
    pass "$label"
    show_output "$output"
  else
    fail "$label"
    show_output "${output:-}"
  fi
  echo
}

if [[ -n "${render_node}" || -e /dev/nvidiactl || -e /dev/kfd ]]; then
  pass "GPU device nodes visible to container"
else
  fail "GPU device nodes visible to container"
fi
echo

if [[ -n "${render_node}" ]]; then
  if runuser -u "${JRMC_USER}" -- test -r "${render_node}"; then
    pass "JRiver service user can read render node"
  else
    fail "JRiver service user can read render node"
  fi
  echo
else
  skip "Render node access check unavailable"
  echo
fi

if command -v ffmpeg >/dev/null 2>&1; then
  run_probe "FFmpeg reports hardware acceleration backends" ffmpeg -hide_banner -hwaccels
else
  skip "FFmpeg not installed"
  echo
fi

if command -v vainfo >/dev/null 2>&1 && [[ -n "${render_node}" ]]; then
  run_probe "VA-API driver probe" runuser -u "${JRMC_USER}" -- vainfo --display drm --device "${render_node}"
else
  skip "VA-API probe unavailable"
  echo
fi

if command -v ffmpeg >/dev/null 2>&1 && [[ -n "${render_node}" ]] && ffmpeg -hide_banner -encoders 2>/dev/null | awk '{print $2}' | grep -qx 'h264_vaapi'; then
  run_probe "FFmpeg VA-API encode" \
    runuser -u "${JRMC_USER}" -- ffmpeg -v error -vaapi_device "${render_node}" -f lavfi -i testsrc2=size=128x128:rate=1 -frames:v 1 -vf format=nv12,hwupload -c:v h264_vaapi -f null -
else
  skip "FFmpeg VA-API encode unavailable"
  echo
fi

if [[ "${has_nvidia_nodes}" == yes ]] && command -v nvidia-smi >/dev/null 2>&1; then
  run_probe "NVIDIA driver probe" nvidia-smi
else
  skip "NVIDIA driver probe unavailable"
  echo
fi

if [[ "${has_nvidia_nodes}" == yes ]] && command -v ffmpeg >/dev/null 2>&1 && ffmpeg -hide_banner -encoders 2>/dev/null | awk '{print $2}' | grep -qx 'h264_nvenc'; then
  run_probe "FFmpeg NVENC encode" \
    runuser -u "${JRMC_USER}" -- ffmpeg -v error -f lavfi -i testsrc2=size=128x72:rate=1 -frames:v 1 -c:v h264_nvenc -f null -
else
  skip "FFmpeg NVENC encode unavailable"
  echo
fi

if (( failures > 0 )); then
  echo "GPU validation completed with ${failures} failure(s)."
  exit 1
fi

echo "GPU validation completed without failures."
EOF
chmod +x /usr/local/bin/jrmc-gpu-test

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

is_popup_window() {
  local props="$1"
  [[ "${props}" == *'JRiver Popup Class'* ]]
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
    is_popup_window "${props}" && continue
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
    is_popup_window "${props}" && continue
    echo "${wid}"
    return 0
  done < <(xdotool search --onlyvisible --pid "${app_pid}" 2>/dev/null || true)

  while read -r wid; do
    [[ -n "${wid}" ]] || continue
    props="$(window_properties "${wid}")"
    [[ -n "${props}" ]] || continue
    is_jriver_window "${props}" || continue
    is_popup_window "${props}" && continue
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

cat <<'EOF' >/usr/local/bin/jrmc-rdp-session-start
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

export HOME="${JRMC_HOME}"
export USER="${JRMC_USER}"
export DISPLAY="${DISPLAY:-:${JRMC_DISPLAY}}"
export XAUTHORITY="${XAUTHORITY:-${JRMC_HOME}/.Xauthority}"
eval "$(/usr/local/bin/jrmc-remote-audio emit-env)"

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

nohup /usr/bin/openbox >/tmp/jrmc-openbox-rdp.log 2>&1 &
openbox_pid=$!
printf '%s\n' "${openbox_pid}" >"${JRMC_RDP_OPENBOX_PIDFILE}"
sleep 1

/usr/local/bin/jrmc-app-scale rdp >/dev/null 2>&1 || true
/usr/local/bin/jrmc-remote-audio sync-jriver-output >/dev/null 2>&1 || true
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
eval "$(/usr/local/bin/jrmc-remote-audio emit-env)"

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

/usr/local/bin/jrmc-app-scale vnc >/dev/null 2>&1 || true
/usr/local/bin/jrmc-remote-audio sync-jriver-output >/dev/null 2>&1 || true
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
eval "$(/usr/local/bin/jrmc-remote-audio emit-env)"

for _i in $(seq 1 30); do
  xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1 && break
  sleep 0.5
done

/usr/local/bin/jrmc-remote-audio sync-jriver-output >/dev/null 2>&1 || true
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

cat <<'EOF' >/usr/local/bin/jrmc-vnc-passwd-sync
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/jrmc

password="${1:-}"

if [[ -z "${password}" ]]; then
  echo "Usage: jrmc-vnc-passwd-sync <password>" >&2
  exit 1
fi

install -d -m 700 -o "${JRMC_USER}" -g "${JRMC_USER}" "$(dirname "${JRMC_VNC_PASSWD_FILE}")"
printf '%s\n' "${password}" | tigervncpasswd -f >"${JRMC_VNC_PASSWD_FILE}"
chown "${JRMC_USER}:${JRMC_USER}" "${JRMC_VNC_PASSWD_FILE}"
chmod 0600 "${JRMC_VNC_PASSWD_FILE}"
EOF
chmod +x /usr/local/bin/jrmc-vnc-passwd-sync

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
/usr/local/bin/jrmc-vnc-passwd-sync "${password}"
touch "${JRMC_BOOTSTRAP_FILE}"
chown root:www-data "${JRMC_WEB_HTPASSWD}"
chmod 0640 "${JRMC_WEB_HTPASSWD}"
chmod 0644 "${JRMC_BOOTSTRAP_FILE}"

cat <<CREDS >/root/jrmc.creds
JRiver Media Center Web Access
==============================
URL: https://$(hostname -I | awk '{print $1}'):${JRMC_WEB_PORT}/setup/
Username: ${username}
Password: ${password}

Default mode: Media Server
Modes: choose Media Server, VNC, or RDP from Dashboard or jrmc-mode.
VNC mode: browser noVNC and direct VNC on port ${JRMC_VNC_PORT} run together against the same JRMC session through one Xtigervnc backend.
VNC authentication: after Dashboard sign-in, use the same Dashboard password when noVNC or a native VNC client prompts for the VNC password.
RDP mode: native RDP on port ${JRMC_NATIVE_RDP_PORT} for Remmina using the same username and password as Dashboard.
UI Scale: set 100%-200% presets from Dashboard or jrmc-scale; active sessions update best-effort.
Remote audio: optionally point JRMC at a trusted-LAN PipeWire Pulse endpoint from Dashboard or jrmc-remote-audio.
GPU passthrough: if enabled during install, validate device visibility and FFmpeg acceleration with jrmc-gpu-status and jrmc-gpu-test.
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
      update_default JRMC_NATIVE_RDP_ENABLED 0
      ;;
    vnc)
      update_default JRMC_NATIVE_RDP_ENABLED 0
      ;;
    rdp)
      update_default JRMC_NATIVE_RDP_ENABLED 1
      ;;
  esac
}

sync_boot_units() {
  local new_mode="$1"
  case "${new_mode}" in
    mediaserver)
      systemctl enable jrmc-mediaserver.service >/dev/null 2>&1 || true
      systemctl disable jrmc-vnc.service jrmc-ui.service jrmc-websockify.service xrdp.service xrdp-sesman.service >/dev/null 2>&1 || true
      ;;
    vnc)
      systemctl enable jrmc-ui.service jrmc-websockify.service >/dev/null 2>&1 || true
      systemctl disable jrmc-mediaserver.service jrmc-vnc.service xrdp.service xrdp-sesman.service >/dev/null 2>&1 || true
      ;;
    rdp)
      systemctl enable xrdp-sesman.service xrdp.service >/dev/null 2>&1 || true
      systemctl disable jrmc-mediaserver.service jrmc-vnc.service jrmc-ui.service jrmc-websockify.service >/dev/null 2>&1 || true
      ;;
  esac
}

current_mode() {
  if systemctl is-active --quiet xrdp.service || systemctl is-active --quiet xrdp-sesman.service || /usr/local/bin/jrmc-pidfile-active "${JRMC_RDP_PIDFILE}" >/dev/null 2>&1; then
    echo "rdp"
  elif systemctl is-active --quiet jrmc-ui.service || systemctl is-active --quiet jrmc-websockify.service; then
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
  systemctl stop jrmc-ui.service jrmc-websockify.service jrmc-vnc.service >/dev/null 2>&1 || true
  rm -f "${JRMC_UI_PIDFILE}"
}

case "${mode}" in
  ui|vnc)
    stop_rdp_runtime
    systemctl stop jrmc-mediaserver.service || true
    systemctl restart jrmc-vnc.service
    systemctl restart jrmc-websockify.service
    systemctl restart jrmc-ui.service
    persist_mode vnc
    sync_boot_units vnc
    echo "JRMC VNC mode started. Browser noVNC and direct VNC now share the same writable JRMC session."
    ;;
  mediaserver|server)
    stop_rdp_runtime
    systemctl stop jrmc-ui.service jrmc-websockify.service || true
    systemctl restart jrmc-vnc.service
    systemctl restart jrmc-mediaserver.service
    persist_mode mediaserver
    sync_boot_units mediaserver
    echo "JRMC Media Server mode started. Interactive VNC and RDP transports were stopped."
    ;;
  rdp)
    systemctl stop jrmc-mediaserver.service >/dev/null 2>&1 || true
    stop_vnc_runtime
    /usr/local/bin/jrmc-stop-rdp-session
    systemctl enable --now xrdp-sesman.service xrdp.service
    persist_mode rdp
    sync_boot_units rdp
    echo "JRMC RDP mode started. VNC transports were stopped so RDP owns the writable JRMC session."
    ;;
  stop-ui)
    stop_vnc_runtime
    persist_mode mediaserver
    sync_boot_units mediaserver
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
    echo "xrdp: $(systemctl is-active xrdp.service 2>/dev/null || true)"
    echo "ui-scale: ${JRMC_UI_SCALE:-100}%"
    echo "gpu-enabled: ${JRMC_GPU_ENABLED:-no}"
    echo "gpu-selected-type: ${JRMC_GPU_SELECTED_TYPE:-auto}"
    echo "remote-audio-enabled: ${JRMC_REMOTE_AUDIO_ENABLED:-0}"
    echo "remote-audio-host: ${JRMC_REMOTE_AUDIO_HOST:-}"
    echo "remote-audio-port: ${JRMC_REMOTE_AUDIO_PORT:-4713}"
    echo "remote-audio-sink: ${JRMC_REMOTE_AUDIO_SINK:-}"
    if [[ "${active_mode}" == "vnc" ]]; then
      echo "novnc: https://$(hostname -I | awk '{print $1}'):${JRMC_WEB_PORT}/novnc/vnc.html?autoconnect=1&resize=scale&path=/websockify"
      echo "direct-vnc: $(hostname -I | awk '{print $1}'):${JRMC_VNC_PORT}"
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
remote_audio_host = params.get("remote_audio_host", [""])[0].strip()
remote_audio_port = params.get("remote_audio_port", [""])[0].strip()
remote_audio_sink = params.get("remote_audio_sink", [""])[0].strip()

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
  "gpu-status": ["sudo", "/usr/local/bin/jrmc-gpu-status"],
  "gpu-test": ["sudo", "/usr/local/bin/jrmc-gpu-test"],
  "disable-remote-audio": ["sudo", "/usr/local/bin/jrmc-remote-audio", "disable"],
  "remote-audio-status": ["sudo", "/usr/local/bin/jrmc-remote-audio", "status"],
}

print("Content-Type: text/html")
print()

if action == "set-ui-scale":
  if scale not in {"100", "125", "150", "175", "200"}:
    print("<html><body><h1>Invalid scale preset</h1><p><a href='/dashboard/'>Back</a></p></body></html>")
    raise SystemExit(0)
  command = ["sudo", "/usr/local/bin/jrmc-scale", "set", scale]
elif action == "enable-remote-audio":
  if not remote_audio_host:
    print("<html><body><h1>Remote audio host is required</h1><p><a href='/dashboard/'>Back</a></p></body></html>")
    raise SystemExit(0)
  port = remote_audio_port or "4713"
  command = ["sudo", "/usr/local/bin/jrmc-remote-audio", "enable", remote_audio_host, port]
  if remote_audio_sink:
    command.append(remote_audio_sink)
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
    input,select{width:100%;padding:.8rem;border-radius:8px;border:1px solid #475569;background:#020617;color:#e2e8f0}
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
    <p>Browser noVNC and direct VNC both connect to the same Xtigervnc server. Direct VNC listens on port <code>5900</code>, and both paths use the same VNC password derived from your Dashboard password.</p>
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
    <p>Scale presets persist for future VNC and RDP sessions. In VNC mode, larger presets request a larger server framebuffer so noVNC can scale it back down cleanly in the browser while JRiver keeps its own internal Standard View size at 1.</p>
    <p>In RDP mode, the same presets are translated into JRiver's internal Standard View size before the app launches, so 100% maps to 1, 125% to 1.25, 150% to 1.5, 175% to 1.75, and 200% to 2.</p>
    <p>For the sharpest result, let noVNC fit the view automatically and prefer 100% / 1:1 client-side scaling in TigerVNC and Remmina when using a larger JRMC scale preset.</p>
  </div>
  <div class="card">
    <h2>Remote Audio</h2>
    <div class="stack">
      <form class="scale-form" method="post" action="/cgi-bin/jrmc-control.py">
        <input type="hidden" name="action" value="enable-remote-audio">
        <label for="remote_audio_host">PipeWire host or IP</label>
        <input id="remote_audio_host" name="remote_audio_host" placeholder="192.168.1.50" required>
        <label for="remote_audio_port">Pulse TCP port</label>
        <input id="remote_audio_port" name="remote_audio_port" value="4713" inputmode="numeric">
        <label for="remote_audio_sink">Optional sink name</label>
        <input id="remote_audio_sink" name="remote_audio_sink" placeholder="alsa_output.pci-0000_00_1f.3.analog-stereo">
        <button type="submit">Enable Remote Audio</button>
      </form>
      <div class="actions">
        <a class="alt" href="/cgi-bin/jrmc-control.py?action=disable-remote-audio">Disable Remote Audio</a>
        <a class="alt" href="/cgi-bin/jrmc-control.py?action=remote-audio-status">Remote Audio Status</a>
      </div>
    </div>
    <p>JRMC can send audio to a trusted-LAN Linux host running PipeWire with local ALSA speakers. When enabled, the active JRMC mode exports <code>PULSE_SERVER=tcp:host:port</code> and optionally <code>PULSE_SINK</code> before the player launches.</p>
    <p>After restarting JRMC, the preferred Linux output device inside JRiver is <code>pulse</code>. The installer writes that descriptor into JRiver's ALSA output settings when remote audio is enabled.</p>
    <p>Remote host setup: install PipeWire with the Pulse compatibility daemon, then configure <code>~/.config/pipewire/pipewire-pulse.conf.d/jrmc-network.conf</code> with <code>pulse.properties = { server.address = [ "unix:native" "tcp:4713" ] }</code>. Restart the user services with <code>systemctl --user restart pipewire pipewire-pulse</code>, confirm the chosen sink name with <code>pactl list short sinks</code>, and keep the listener restricted to a trusted LAN.</p>
    <p>After enabling or changing the target, switch JRMC modes or reconnect the current session so the player relaunches against the new audio endpoint.</p>
  </div>
  <div class="card">
    <h2>GPU Passthrough</h2>
    <div class="actions">
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=gpu-status">GPU Status</a>
      <a class="alt" href="/cgi-bin/jrmc-control.py?action=gpu-test">Run GPU Validation</a>
    </div>
    <p>If GPU passthrough was enabled during installation, the container should expose either <code>/dev/dri/renderD*</code> or <code>/dev/nvidia*</code> devices to JRiver and FFmpeg.</p>
    <p><code>jrmc-gpu-status</code> summarizes visible GPU nodes, service-user group membership, and detected FFmpeg hardware backends. <code>jrmc-gpu-test</code> runs command-line validation with <code>vainfo</code>, <code>nvidia-smi</code>, and a tiny FFmpeg hardware encode where supported.</p>
    <p>JRiver on Linux relies on the guest VA-API or NVIDIA stack provided by the container. Validate here first, then do interactive playback checks from VNC or RDP mode for app-level confirmation.</p>
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
www-data ALL=(root) NOPASSWD: /usr/local/bin/jrmc-mode, /usr/local/bin/jrmc-scale, /usr/local/bin/jrmc-remote-audio, /usr/local/bin/jrmc-gpu-status, /usr/local/bin/jrmc-gpu-test, /usr/local/bin/jrmc-set-web-credentials
EOF
chmod 0440 /etc/sudoers.d/jrmc-web


if [[ -f /etc/X11/xrdp/xorg.conf ]]; then
  render_node="$(find /dev/dri -maxdepth 1 -name 'renderD*' 2>/dev/null | sort | head -n1 || true)"
  if [[ -n "${render_node}" ]]; then
    sed -i "s#^\([[:space:]]*Option \"DRMDevice\" \)\"[^\"]*\"#\1\"${render_node}\"#" /etc/X11/xrdp/xorg.conf
  fi
  if grep -q 'Option "DRMAllowList"' /etc/X11/xrdp/xorg.conf; then
    sed -i 's#^\([[:space:]]*Option "DRMAllowList" \)"[^"]*"#\1"i915 radeon amdgpu nouveau"#' /etc/X11/xrdp/xorg.conf
  fi
fi

cat <<EOF >/etc/systemd/system/jrmc-vnc.service
[Unit]
Description=JRiver Media Center shared Xtigervnc backend
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
echo "VNC mode:             Browser noVNC plus direct VNC on port 5900 through one Xtigervnc server"
echo "UI Scale:             Presets 100/125/150/175/200 via Dashboard or jrmc-scale"
echo "RDP mode:             Port 3389 for Remmina using the same Dashboard username; switching modes tears down the others first"
echo "GPU passthrough:      Validate with jrmc-gpu-status and jrmc-gpu-test when enabled at install time"
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
  "Show GPU status" \
  "Run GPU validation" \
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
  "Show GPU status")
    /usr/local/bin/jrmc-gpu-status
    ;;
  "Run GPU validation")
    /usr/local/bin/jrmc-gpu-test
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
