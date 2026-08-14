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
#   QODEX_ORIENTATION=inverted     rotación fija del framebuffer. Acepta grados
#                                  (0, 90, 180, 270, 360) o palabras
#                                  (normal|right|inverted|left).
#                                  0/360=sin giro, 90=horario, 180=de cabeza,
#                                  270=antihorario. Default: inverted (180°),
#                                  el tótem omnios estándar.
#   QODEX_GPIO_RTSP=1              1 = instalar supervisor botón GPIO→cámara (default 1)
#   QODEX_GPIO_PIN=22              pin BCM del botón/relé de llamada (default 22)
#   QODEX_CAM_ROTATE=90            rotación del video de la cámara (0|90|180|270).
#                                  Default: el mismo valor que la pantalla offline.
#   QODEX_OFFLINE_ROTATE=90        rotación de la pantalla "Sin conexión" (0|90|180|270).
#                                  Default: 90 cuando la orientación es inverted (la
#                                  campaña omnios se auto-rota), 0 en el resto.
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
GPIO_PIN="${QODEX_GPIO_PIN:-22}"
CONFIG_DIR="$KIOSK_HOME/.config/@workspace/desktop-kiosk"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: ejecutar con sudo/root" >&2
  exit 1
fi
if [ -z "$KIOSK_HOME" ] || [ ! -d "$KIOSK_HOME" ]; then
  echo "ERROR: usuario '$KIOSK_USER' sin home válido" >&2
  exit 1
fi

# Grados → palabra clave de xrandr (90 = horario, 270 = antihorario).
case "$ORIENTATION" in
  0|360) ORIENTATION="normal" ;;
  90)    ORIENTATION="right" ;;
  180)   ORIENTATION="inverted" ;;
  270)   ORIENTATION="left" ;;
esac
case "$ORIENTATION" in
  normal)   TOUCH_MATRIX="1 0 0 0 1 0 0 0 1" ;;
  left)     TOUCH_MATRIX="0 -1 1 1 0 0 0 0 1" ;;
  right)    TOUCH_MATRIX="0 1 0 -1 0 1 0 0 1" ;;
  inverted) TOUCH_MATRIX="-1 0 1 0 -1 1 0 0 1" ;;
  *) echo "ERROR: QODEX_ORIENTATION debe ser 0|90|180|270 o normal|right|inverted|left" >&2; exit 1 ;;
esac
echo "== Orientación: $ORIENTATION =="

# La campaña omnios dibuja su contenido rotado 90° cuando el framebuffer va
# en inverted; la pantalla offline local debe rotarse igual.
if [ -n "${QODEX_OFFLINE_ROTATE:-}" ]; then
  OFFLINE_ROTATE="$QODEX_OFFLINE_ROTATE"
elif [ "$ORIENTATION" = "inverted" ]; then
  OFFLINE_ROTATE="90"
else
  OFFLINE_ROTATE="0"
fi
CAM_ROTATE="${QODEX_CAM_ROTATE:-$OFFLINE_ROTATE}"

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
# Rotacion de la pantalla "Sin conexion" local (ver QODEX_OFFLINE_ROTATE).
export QODEX_OFFLINE_ROTATE=$OFFLINE_ROTATE

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
  cat > "$QODEX_DIR/gpio-rtsp.py" <<'GPIOEOF'
#!/usr/bin/env python3
"""Boton GPIO -> camara RTSP a pantalla completa, sobre el kiosko QodeX.

Mientras el boton/rele (QODEX_GPIO_PIN, BCM, default 22; pull-up) este
presionado y haya una URL rtsp:// valida en rtsp_url.txt (la escribe
config_editor al detectar la llamada via AMI), se muestra la camara en
fullscreen ENCIMA de la ventana del kiosko. Al soltarse: se cierra el
reproductor, se vacia rtsp_url.txt y se reinicia config_editor — mismo
contrato que el run.py anterior.

Reproductor: ffplay con RENDERIZADO POR SOFTWARE (en esta plataforma la
salida por hardware pinta NEGRO con el kiosko Electron activo — mismo
hallazgo que el sip-proxy-pilot de TI). Fallback: VLC con salida X11
software. QODEX_CAM_ROTATE (0|90|180|270, default 90) rota el video para
el montaje fisico del totem, igual que la pantalla offline.

Todo evento queda en journal (journalctl -u qodex-gpio) para diagnostico:
presion/liberacion del boton, contenido de rtsp_url.txt, arranque/muerte
del reproductor con su codigo de salida.
"""
from gpiozero import Button
import os
import shutil
import subprocess
import time

RTSP_FILE = os.path.expanduser("~/Desktop/rtsp_url.txt")
ENV = dict(
    os.environ,
    DISPLAY=":0",
    XAUTHORITY=os.path.expanduser("~/.Xauthority"),
    SDL_RENDER_DRIVER="software",
)
WAIT_LOG_EVERY_S = 2.0
PLAYER_RESPAWN_DELAY_S = 1.0
GPIO_PIN = int(os.environ.get("QODEX_GPIO_PIN", "22"))
CAM_ROTATE = os.environ.get("QODEX_CAM_ROTATE", "90")
if CAM_ROTATE not in ("0", "90", "180", "270"):
    CAM_ROTATE = "90"

FFPLAY_TRANSPOSE = {
    "0": None,
    "90": "transpose=1",
    "180": "transpose=1,transpose=1",
    "270": "transpose=2",
}[CAM_ROTATE]

boton = Button(GPIO_PIN, pull_up=True)
player = None
current_url = None
was_pressed = False
last_wait_log = 0.0
player_died_at = 0.0


def log(msg):
    print(f"[gpio-rtsp] {msg}", flush=True)


def read_rtsp():
    try:
        with open(RTSP_FILE) as f:
            return f.readline().strip()
    except OSError:
        return None


def start_player(url):
    """ffplay software (receta probada del sip-proxy-pilot) o VLC x11."""
    if shutil.which("ffplay"):
        cmd = [
            "ffplay", "-fs", "-an", "-hide_banner", "-loglevel", "warning",
            "-alwaysontop",
            "-rtsp_transport", "tcp",
            "-fflags", "nobuffer", "-flags", "low_delay", "-framedrop",
            "-analyzeduration", "0", "-probesize", "32768",
        ]
        if FFPLAY_TRANSPOSE:
            cmd += ["-vf", FFPLAY_TRANSPOSE]
        cmd.append(url)
        log(f"lanzando ffplay (rotacion {CAM_ROTATE}°)")
    else:
        cmd = [
            "cvlc", "--fullscreen", "--video-on-top", "--no-osd",
            "--rtsp-tcp", "--no-video-title", "--no-audio",
            "--avcodec-hw=none", "--vout=xcb_x11",
            "--network-caching=100", "--live-caching=0",
            "--clock-jitter=0", "--clock-synchro=0",
        ]
        if CAM_ROTATE != "0":
            cmd += ["--video-filter=transform", f"--transform-type={CAM_ROTATE}"]
        cmd.append(url)
        log(f"ffplay no disponible — lanzando VLC x11 software (rotacion {CAM_ROTATE}°)")
    # stderr hereda al journal para ver errores de conexion RTSP en campo.
    return subprocess.Popen(cmd, env=ENV, stdout=subprocess.DEVNULL)


def kill_player():
    global player
    if player is not None:
        player.terminate()
        try:
            player.wait(timeout=2)
        except subprocess.TimeoutExpired:
            player.kill()
        player = None
    for pattern in ("ffplay", "vlc"):
        subprocess.run(["pkill", "-f", pattern],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def back_to_kiosk():
    """Mismo retorno que el run.py anterior: cerrar camara, limpiar RTSP,
    reiniciar config_editor para dejar el listener AMI fresco."""
    kill_player()
    try:
        with open(RTSP_FILE, "w") as f:
            f.write("")
        log("rtsp_url.txt vaciado")
    except OSError as e:
        log(f"ERROR al vaciar rtsp_url.txt: {e}")
    r = subprocess.run(["sudo", "-n", "systemctl", "restart", "config_editor"],
                       capture_output=True, text=True)
    if r.returncode == 0:
        log("config_editor reiniciado")
    else:
        log(f"AVISO: no se pudo reiniciar config_editor (rc={r.returncode}): {r.stderr.strip()[:120]}")


log(f"supervisor iniciado (GPIO {GPIO_PIN}, pull-up, rotacion camara {CAM_ROTATE}°)")
log(f"estado inicial del boton: {'PRESIONADO' if boton.is_pressed else 'suelto'}; rtsp_url.txt: {read_rtsp()!r}")
try:
    while True:
        pressed = boton.is_pressed
        now = time.time()

        if pressed and not was_pressed:
            log(f"boton PRESIONADO — rtsp_url.txt: {read_rtsp()!r}")

        if pressed:
            url = read_rtsp()
            valid = bool(url and url.startswith("rtsp://"))
            player_running = player is not None and player.poll() is None

            if player is not None and player.poll() is not None:
                log(f"reproductor murio (rc={player.returncode}) con boton presionado — reintento en {PLAYER_RESPAWN_DELAY_S}s")
                player = None
                player_died_at = now
                current_url = None

            if valid and not player_running and (now - player_died_at) >= PLAYER_RESPAWN_DELAY_S:
                kill_player()
                player = start_player(url)
                current_url = url
                log(f"reproductor lanzado (pid={player.pid}) mostrando {url}")
            elif valid and player_running and url != current_url:
                log(f"RTSP cambio {current_url} -> {url} — relanzando")
                kill_player()
                player = start_player(url)
                current_url = url
            elif not valid and (now - last_wait_log) >= WAIT_LOG_EVERY_S:
                log(f"esperando RTSP valido... (contenido actual: {url!r})")
                last_wait_log = now

        elif was_pressed:
            log("boton SOLTADO — volviendo al kiosko")
            back_to_kiosk()
            current_url = None

        was_pressed = pressed
        time.sleep(0.2)
finally:
    kill_player()
GPIOEOF
  chmod +x "$QODEX_DIR/gpio-rtsp.py"

  cat > /etc/systemd/system/qodex-gpio.service <<EOF
[Unit]
Description=QodeX GPIO -> camara RTSP (sobre el kiosko)
StartLimitIntervalSec=0
After=qodex-kiosk.service

[Service]
Type=simple
User=$KIOSK_USER
Group=$KIOSK_USER
ExecStart=/usr/bin/python3 $QODEX_DIR/gpio-rtsp.py
WorkingDirectory=$QODEX_DIR
Environment=QODEX_GPIO_PIN=$GPIO_PIN
Environment=QODEX_CAM_ROTATE=$CAM_ROTATE
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
StartLimitIntervalSec=0
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
