#!/bin/bash
# =============================================================================
# QodeX KioskOS — aprovisionamiento de tótem Raspberry Pi (X11/openbox)
#
# Replica la instalación de referencia del tótem omnios: AppImage + servicio
# systemd (xinit), botón GPIO 17 → cámara RTSP con VLC, rotación de pantalla
# y matriz táctil coherentes. Idempotente: re-ejecutar actualiza el AppImage
# y reescribe la configuración sin duplicar nada.
#
# Uso (en la Pi, como root):
#   sudo bash totem-setup.sh
#
# O directo desde GitHub:
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/torresjr94dev/qodex-kioskos-releases/main/totem-setup.sh)"
#
# Variables (todas opcionales, se pasan antes del comando):
#   KIOSK_USER=toor                usuario que corre el kiosko (default: quien invoca sudo)
#   QODEX_BASE_URL=https://...     servidor QodeX (default kioskos.replit.app)
#   QODEX_ENROLL_TOKEN=xxxx        token de enrolamiento → vincula SIN tocar la pantalla.
#                                  Sin token, el tótem muestra el código de vinculación.
#   QODEX_ORIENTATION=inverted     rotación fija del framebuffer: normal|left|right|inverted
#                                  (default inverted = tótem omnios estándar)
#   QODEX_GPIO_RTSP=1              1 = instalar supervisor botón GPIO→cámara (default 1)
#   QODEX_VERSION=0.2.6            fija una versión; default = última release pública
#
# Ejemplo de aprovisionamiento masivo de una unidad:
#   sudo QODEX_ENROLL_TOKEN=abc123 bash totem-setup.sh
# =============================================================================
set -euo pipefail

RELEASES_REPO="torresjr94dev/qodex-kioskos-releases"
KIOSK_USER="${KIOSK_USER:-${SUDO_USER:-toor}}"
KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
QODEX_DIR="$KIOSK_HOME/qodex"
BASE_URL="${QODEX_BASE_URL:-https://kioskos.replit.app}"
ORIENTATION="${QODEX_ORIENTATION:-inverted}"
GPIO_RTSP="${QODEX_GPIO_RTSP:-1}"
CONFIG_DIR="$KIOSK_HOME/.config/@workspace/desktop-kiosk"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: ejecutar con sudo/root" >&2
  exit 1
fi
if [ -z "$KIOSK_HOME" ] || [ ! -d "$KIOSK_HOME" ]; then
  echo "ERROR: usuario '$KIOSK_USER' sin home válido" >&2
  exit 1
fi

case "$ORIENTATION" in
  normal)   TOUCH_MATRIX="1 0 0 0 1 0 0 0 1" ;;
  left)     TOUCH_MATRIX="0 -1 1 1 0 0 0 0 1" ;;
  right)    TOUCH_MATRIX="0 1 0 -1 0 1 0 0 1" ;;
  inverted) TOUCH_MATRIX="-1 0 1 0 -1 1 0 0 1" ;;
  *) echo "ERROR: QODEX_ORIENTATION debe ser normal|left|right|inverted" >&2; exit 1 ;;
esac

echo "== [1/7] Dependencias apt =="
export DEBIAN_FRONTEND=noninteractive
# Un repositorio de terceros roto (llave GPG vencida, mirror caído) no debe
# abortar el aprovisionamiento: los paquetes que necesitamos vienen de los
# repos oficiales de Raspberry Pi OS. Si el update falla por completo, el
# install de abajo fallará con un error claro de paquete faltante.
if ! apt-get update -qq 2>/dev/null; then
  echo "   AVISO: apt-get update reportó errores (repo de terceros roto?) — continuando"
fi
apt-get install -y -qq libfuse2 xserver-xorg xinit x11-xserver-utils xinput \
  openbox xdotool vlc curl python3-gpiozero python3-lgpio >/dev/null

# xinit desde systemd necesita permiso para arrancar X sin consola activa.
cat > /etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

echo "== [2/7] Descarga del AppImage =="
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64) ASSET_ARCH="arm64" ;;
  armv7l)  ASSET_ARCH="armv7l" ;;
  x86_64)  ASSET_ARCH="x86_64" ;;
  *) echo "ERROR: arquitectura no soportada: $ARCH" >&2; exit 1 ;;
esac
if [ -n "${QODEX_VERSION:-}" ]; then
  VERSION="$QODEX_VERSION"
else
  VERSION="$(curl -fsSL "https://api.github.com/repos/$RELEASES_REPO/releases/latest" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].replace("desktop-v",""))')"
fi
echo "   versión: $VERSION ($ASSET_ARCH)"
mkdir -p "$QODEX_DIR"
APPIMAGE_URL="https://github.com/$RELEASES_REPO/releases/download/desktop-v$VERSION/qodex-kioskos-desktop-$VERSION-$ASSET_ARCH.AppImage"
curl -fsSL -o "$QODEX_DIR/qodex-new.AppImage" "$APPIMAGE_URL"
chmod +x "$QODEX_DIR/qodex-new.AppImage"
mv "$QODEX_DIR/qodex-new.AppImage" "$QODEX_DIR/qodex-kioskos.AppImage"

echo "== [3/7] Lanzador X11 =="
cat > "$QODEX_DIR/launch-qodex.sh" <<EOF
#!/bin/bash
# QodeX KioskOS — lanzador X11 (generado por totem-setup.sh, no editar a mano;
# re-ejecuta el setup con otras variables para cambiar la configuracion)
xset -dpms
xset s off
xset s noblank
export DISPLAY=:0
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=Openbox
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
mkdir -p "\$XDG_RUNTIME_DIR"; chmod 700 "\$XDG_RUNTIME_DIR"

# Rotacion fija del totem: la app (0.2.5+) la aplica SIEMPRE, ignorando la
# orientacion del panel. El contenido de omnios se auto-rota para pantalla
# horizontal, por eso el valor tipico es "inverted" (montaje volteado).
export QODEX_ORIENTATION_OVERRIDE=$ORIENTATION
export QODEX_PORTRAIT_DIRECTION=left
# Sin compositor X11 el overlay del gesto de salida se ve como cuadro negro.
export QODEX_DISABLE_EXIT_OVERLAY=1

openbox &
sleep 2

xrandr --output HDMI-1 --mode 1280x720 --rotate $ORIENTATION || true

sleep 1
# Touch PQLabs/USBest: matriz coherente con la rotacion elegida.
xinput list | grep -iE "PQLabs|USBest" | grep -oP 'id=\\K\\d+' | while read -r device_id; do
    xinput set-prop "\$device_id" "Coordinate Transformation Matrix" $TOUCH_MATRIX 2>/dev/null \\
      && echo "OK: touch $ORIENTATION (id=\$device_id)"
done

exec $QODEX_DIR/qodex-kioskos.AppImage
EOF
chmod +x "$QODEX_DIR/launch-qodex.sh"

echo "== [4/7] Supervisor GPIO -> RTSP =="
if [ "$GPIO_RTSP" = "1" ]; then
  cat > "$QODEX_DIR/gpio-rtsp.py" <<EOF
#!/usr/bin/env python3
"""Boton GPIO 17 -> camara RTSP a pantalla completa, sobre el kiosko QodeX.

Mientras el boton/rele (GPIO 17, pull-up) este presionado y haya una URL
rtsp:// valida en rtsp_url.txt, VLC muestra la camara en fullscreen ENCIMA
de la ventana del kiosko. Al soltarse: se cierra VLC, se vacia rtsp_url.txt
y se reinicia config_editor (si existe)."""
from gpiozero import Button
import os
import subprocess
import time

RTSP_FILE = "$KIOSK_HOME/Desktop/rtsp_url.txt"
ENV = dict(os.environ, DISPLAY=":0", XAUTHORITY="$KIOSK_HOME/.Xauthority")

boton = Button(17, pull_up=True)
vlc = None
current_url = None
was_pressed = False


def read_rtsp():
    try:
        with open(RTSP_FILE) as f:
            return f.readline().strip()
    except OSError:
        return None


def start_vlc(url):
    return subprocess.Popen(
        [
            "cvlc", "--fullscreen", "--no-osd", "--rtsp-tcp",
            "--no-video-title", "--no-audio", "--network-caching=300", url,
        ],
        env=ENV,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def kill_vlc():
    global vlc
    if vlc is not None:
        vlc.terminate()
        try:
            vlc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            vlc.kill()
        vlc = None
    subprocess.run(["pkill", "-f", "vlc"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def back_to_kiosk():
    kill_vlc()
    try:
        with open(RTSP_FILE, "w") as f:
            f.write("")
        print("[ok] rtsp_url.txt vaciado")
    except OSError as e:
        print(f"[err] no se pudo vaciar rtsp_url.txt: {e}")
    subprocess.run(["sudo", "systemctl", "restart", "config_editor"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


print("[gpio-rtsp] supervisor iniciado (GPIO 17)")
try:
    while True:
        pressed = boton.is_pressed
        if pressed:
            url = read_rtsp()
            valid = url and url.startswith("rtsp://")
            vlc_dead = vlc is None or vlc.poll() is not None
            if valid and (vlc_dead or url != current_url):
                if not vlc_dead:
                    print(f"[cambio] RTSP {current_url} -> {url}")
                kill_vlc()
                vlc = start_vlc(url)
                current_url = url
                print(f"[camara] mostrando {url}")
        elif was_pressed:
            print("[boton] soltado — volviendo al kiosko")
            back_to_kiosk()
            current_url = None
        was_pressed = pressed
        time.sleep(0.2)
finally:
    kill_vlc()
EOF
  chmod +x "$QODEX_DIR/gpio-rtsp.py"

  cat > /etc/systemd/system/qodex-gpio.service <<EOF
[Unit]
Description=QodeX GPIO 17 -> camara RTSP (VLC sobre el kiosko)
After=qodex-kiosk.service

[Service]
Type=simple
User=$KIOSK_USER
Group=$KIOSK_USER
ExecStart=/usr/bin/python3 $QODEX_DIR/gpio-rtsp.py
WorkingDirectory=$QODEX_DIR
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$KIOSK_USER")
Environment=PYTHONUNBUFFERED=1
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
else
  echo "   (desactivado con QODEX_GPIO_RTSP=0)"
fi

echo "== [5/7] Servicio del kiosko =="
cat > /etc/systemd/system/qodex-kiosk.service <<EOF
[Unit]
Description=QodeX KioskOS (Electron kiosk)
After=multi-user.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$KIOSK_USER
Group=$KIOSK_USER
ExecStart=/usr/bin/xinit $QODEX_DIR/launch-qodex.sh -- :0 -nocursor
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$KIOSK_USER")
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "== [6/7] Enrolamiento =="
TOKEN_FILE="$CONFIG_DIR/device-token.json"
if [ -n "${QODEX_ENROLL_TOKEN:-}" ] && [ ! -f "$TOKEN_FILE" ]; then
  MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || uname -m)"
  ENROLL_RESPONSE="$(curl -fsSL -X POST "$BASE_URL/api/provision/enroll" \
    -H 'Content-Type: application/json' \
    -d "$(python3 - "$QODEX_ENROLL_TOKEN" "$MODEL" "$VERSION" <<'PYEOF'
import json, platform, sys
print(json.dumps({
    "enrollmentToken": sys.argv[1],
    "manufacturer": "Raspberry Pi Foundation",
    "model": sys.argv[2],
    "androidVersion": platform.release(),
    "appVersion": sys.argv[3],
    "platform": "raspberry_pi",
}))
PYEOF
)")" || { echo "ERROR: enrolamiento falló — revisa el token"; exit 1; }
  mkdir -p "$CONFIG_DIR"
  ENROLL_RESPONSE="$ENROLL_RESPONSE" BASE_URL="$BASE_URL" python3 - "$CONFIG_DIR" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone
resp = json.loads(os.environ["ENROLL_RESPONSE"])
cfgdir = sys.argv[1]
config = {
    "baseUrl": os.environ["BASE_URL"],
    "deviceId": resp["deviceId"],
    "deviceName": resp["config"].get("deviceName"),
    "enrolledAt": datetime.now(timezone.utc).isoformat(),
    "lastConfig": resp["config"],
    "latitude": None,
    "longitude": None,
}
with open(os.path.join(cfgdir, "config.json"), "w") as f:
    json.dump(config, f, indent=2)
tok = os.path.join(cfgdir, "device-token.json")
with open(tok, "w") as f:
    json.dump({"deviceToken": resp["deviceToken"]}, f)
os.chmod(tok, 0o600)
print("   enrolado como:", config["deviceName"] or resp["deviceId"])
PYEOF
elif [ -f "$TOKEN_FILE" ] || [ -f "$CONFIG_DIR/config.json" ]; then
  echo "   ya enrolado — se conserva la vinculación existente"
else
  echo "   sin QODEX_ENROLL_TOKEN — el tótem mostrará el código de vinculación"
fi
chown -R "$KIOSK_USER:$KIOSK_USER" "$QODEX_DIR" "$KIOSK_HOME/.config" 2>/dev/null || true

echo "== [7/7] Activar servicios =="
# Desactivar el kiosko Brave anterior si existe (respaldado, no borrado).
if systemctl list-unit-files run.service >/dev/null 2>&1 && systemctl is-enabled run.service >/dev/null 2>&1; then
  mkdir -p "$KIOSK_HOME/qodex-backup"
  cp -n /etc/systemd/system/run.service "$KIOSK_HOME/qodex-backup/" 2>/dev/null || true
  systemctl disable --now run.service || true
  echo "   run.service (Brave) desactivado — respaldo en qodex-backup/"
fi
systemctl daemon-reload
systemctl enable qodex-kiosk.service >/dev/null
if [ "$GPIO_RTSP" = "1" ]; then systemctl enable qodex-gpio.service >/dev/null; fi
systemctl restart qodex-kiosk.service
if [ "$GPIO_RTSP" = "1" ]; then systemctl restart qodex-gpio.service; fi

sleep 8
echo ""
echo "======================================================"
echo " QodeX KioskOS $VERSION instalado"
echo "   kiosko : $(systemctl is-active qodex-kiosk.service)"
if [ "$GPIO_RTSP" = "1" ]; then
  echo "   gpio   : $(systemctl is-active qodex-gpio.service)"
fi
if [ -f "$TOKEN_FILE" ] || [ -f "$CONFIG_DIR/config.json" ]; then
  echo "   estado : enrolado — el kiosko carga la página del panel"
else
  echo "   estado : SIN enrolar — vincula con el código en pantalla"
fi
echo "======================================================"
