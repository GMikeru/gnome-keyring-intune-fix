#!/bin/bash
# ============================================================
# DIAGNÓSTICO GNOME KEYRING + INTUNE + ENTRA ID
# Executar como root (sudo)
# Não altera nada — apenas coleta informações
# ============================================================

# --- 0. Verificar root ---
if [ "$EUID" -ne 0 ]; then
  echo "ERRO: Este script precisa ser executado como root (sudo)."
  exit 1
fi

echo "========================================"
echo " DIAGNÓSTICO KEYRING/INTUNE"
echo " $(hostname) — $(date)"
echo "========================================"

# --- 1. Sistema ---
echo ""
echo "=== 1. SISTEMA ==="
echo "Hostname: $(hostname)"
. /etc/os-release 2>/dev/null
echo "SO: $PRETTY_NAME"
echo "Kernel: $(uname -r)"
echo "Desktop: ${XDG_CURRENT_DESKTOP:-N/A (sessão root)}"

# --- 2. Pacotes ---
echo ""
echo "=== 2. PACOTES ==="
for PKG in intune-portal microsoft-identity-broker microsoft-edge-stable gnome-keyring libsecret-tools python3-secretstorage authd; do
  if dpkg -l "$PKG" 2>/dev/null | grep -q "^ii"; then
    VER=$(dpkg -l "$PKG" 2>/dev/null | awk '/^ii/{print $3}')
    echo "  $PKG: INSTALADO ($VER)"
  else
    echo "  $PKG: NÃO INSTALADO"
  fi
done
echo "  authd-msentraid (snap): $(snap list authd-msentraid 2>/dev/null | awk 'NR==2{print $2}' || echo 'NÃO INSTALADO')"

# --- 3. Serviços ---
echo ""
echo "=== 3. SERVIÇOS ==="
for SVC in intune-daemon authd gdm; do
  STATUS=$(systemctl is-active "$SVC" 2>/dev/null || echo "não encontrado")
  ENABLED=$(systemctl is-enabled "$SVC" 2>/dev/null || echo "?")
  echo "  $SVC: $STATUS (enabled: $ENABLED)"
done

# --- 4. Usuários e sessões ---
echo ""
echo "=== 4. USUÁRIOS E SESSÕES ==="
for USER_HOME in /home/*; do
  [ -d "$USER_HOME" ] || continue
  USERNAME=$(basename "$USER_HOME")
  id "$USERNAME" >/dev/null 2>&1 || { echo "  $USERNAME: diretório existe, mas usuário não existe no sistema"; continue; }
  UID_NUM=$(id -u "$USERNAME")
  GROUPS=$(id -Gn "$USERNAME" 2>/dev/null | tr ' ' ',')

  # Sessão gráfica ativa?
  LOGGED_IN="NÃO"
  if loginctl list-sessions --no-legend 2>/dev/null | grep -q "$USERNAME"; then
    LOGGED_IN="SIM"
  fi

  # Daemon rodando?
  DAEMON_PID=$(pgrep -u "$USERNAME" -f gnome-keyring-daemon 2>/dev/null | head -1)
  if [ -n "$DAEMON_PID" ]; then
    DAEMON_STATUS="RODANDO (PID $DAEMON_PID)"
    DAEMON_CMD=$(cat /proc/$DAEMON_PID/cmdline 2>/dev/null | tr '\0' ' ')
  else
    DAEMON_STATUS="PARADO"
    DAEMON_CMD=""
  fi

  # D-Bus disponível?
  DBUS_SOCKET="/run/user/$UID_NUM/bus"
  DBUS_OK="NÃO"
  [ -S "$DBUS_SOCKET" ] && DBUS_OK="SIM"

  echo "  --- $USERNAME (UID $UID_NUM) ---"
  echo "      Sessão ativa: $LOGGED_IN"
  echo "      Grupos: $GROUPS"
  echo "      gnome-keyring-daemon: $DAEMON_STATUS"
  [ -n "$DAEMON_CMD" ] && echo "      CMD: $DAEMON_CMD"
  echo "      D-Bus socket: $DBUS_OK ($DBUS_SOCKET)"
done

# --- 5. Keyrings ---
echo ""
echo "=== 5. KEYRINGS ==="
for USER_HOME in /home/*; do
  [ -d "$USER_HOME" ] || continue
  USERNAME=$(basename "$USER_HOME")
  id "$USERNAME" >/dev/null 2>&1 || continue
  KDIR="$USER_HOME/.local/share/keyrings"

  echo "  --- $USERNAME ---"
  if [ -d "$KDIR" ]; then
    echo "      Diretório: $KDIR (existe)"
    echo "      Permissões: $(stat -c '%a %U:%G' "$KDIR" 2>/dev/null)"
    KFILES=$(find "$KDIR" -maxdepth 1 -type f 2>/dev/null)
    if [ -n "$KFILES" ]; then
      echo "$KFILES" | while read -r KF; do
        FNAME=$(basename "$KF")
        FSIZE=$(stat -c%s "$KF" 2>/dev/null)
        FPERMS=$(stat -c '%a %U:%G' "$KF" 2>/dev/null)
        FMOD=$(stat -c '%y' "$KF" 2>/dev/null | cut -d. -f1)
        echo "      $FNAME: ${FSIZE} bytes | $FPERMS | $FMOD"
      done
    else
      echo "      (diretório vazio — SEM keyrings)"
    fi
  else
    echo "      Diretório: NÃO EXISTE"
  fi
done

# --- 6. PAM ---
echo ""
echo "=== 6. PAM (gnome-keyring) ==="
for PAM_FILE in /etc/pam.d/gdm-authd /etc/pam.d/gdm-password /etc/pam.d/gdm-autologin /etc/pam.d/common-auth /etc/pam.d/common-session; do
  if [ -f "$PAM_FILE" ]; then
    HAS_GKR=$(grep -c pam_gnome_keyring "$PAM_FILE" 2>/dev/null)
    if [ "$HAS_GKR" -gt 0 ]; then
      echo "  $PAM_FILE: CONFIGURADO ($HAS_GKR linhas)"
      grep pam_gnome_keyring "$PAM_FILE" | sed 's/^/      /'
    else
      echo "  $PAM_FILE: SEM gnome-keyring"
    fi
  else
    echo "  $PAM_FILE: ARQUIVO NÃO EXISTE"
  fi
done

# --- 7. Autostart ---
echo ""
echo "=== 7. AUTOSTART ==="
for AFILE in /etc/xdg/autostart/unlock-keyring-intune.desktop /etc/xdg/autostart/create-keyring-intune.desktop; do
  if [ -f "$AFILE" ]; then
    echo "  $AFILE: EXISTE"
    grep "^Exec=" "$AFILE" | sed 's/^/      /'
  else
    echo "  $AFILE: NÃO EXISTE"
  fi
done

# --- 8. Intune ---
echo ""
echo "=== 8. INTUNE ==="
# Binários
[ -f /opt/microsoft/intune/bin/intune-portal ] && echo "  intune-portal: EXISTE" || echo "  intune-portal: NÃO ENCONTRADO"
[ -f /opt/microsoft/intune/bin/intune-agent ] && echo "  intune-agent: EXISTE" || echo "  intune-agent: NÃO ENCONTRADO"
[ -f /opt/microsoft/intune/bin/intune-daemon ] && echo "  intune-daemon: EXISTE" || echo "  intune-daemon: NÃO ENCONTRADO"

# Sudoers
if [ -f /etc/sudoers.d/intune-nopasswd ]; then
  echo "  sudoers: CONFIGURADO"
else
  echo "  sudoers: NÃO CONFIGURADO"
fi

# Polkit
[ -f /etc/polkit-1/rules.d/10-intune-admin.rules ] && echo "  polkit rules: EXISTE" || echo "  polkit rules: NÃO EXISTE"
[ -f /etc/polkit-1/localauthority/50-local.d/10-intune-elevation.pkla ] && echo "  polkit pkla: EXISTE" || echo "  polkit pkla: NÃO EXISTE"

# Override
[ -f /etc/systemd/system/intune-daemon.service.d/no-auth-prompt.conf ] && echo "  systemd override: EXISTE" || echo "  systemd override: NÃO EXISTE"

# Timer
systemctl --global is-enabled intune-sync.timer 2>/dev/null && echo "  intune-sync timer: ATIVO" || echo "  intune-sync timer: NÃO ATIVO"

# Cache/config por usuário
for USER_HOME in /home/*; do
  [ -d "$USER_HOME" ] || continue
  USERNAME=$(basename "$USER_HOME")
  id "$USERNAME" >/dev/null 2>&1 || continue
  INTUNE_CACHE="$USER_HOME/.cache/intune-portal"
  INTUNE_CONFIG="$USER_HOME/.config/intune-portal"
  BROKER_CONFIG="$USER_HOME/.config/microsoft-identity-broker"
  BROKER_STATE="$USER_HOME/.local/state/microsoft-identity-broker"
  PARTS=""
  [ -d "$INTUNE_CACHE" ] && PARTS="${PARTS}cache=$(find "$INTUNE_CACHE" -type f 2>/dev/null | wc -l) "
  [ -d "$INTUNE_CONFIG" ] && PARTS="${PARTS}config=$(find "$INTUNE_CONFIG" -type f 2>/dev/null | wc -l) "
  [ -d "$BROKER_CONFIG" ] && PARTS="${PARTS}broker-config=SIM "
  [ -d "$BROKER_STATE" ] && PARTS="${PARTS}broker-state=SIM "
  [ -n "$PARTS" ] && echo "  $USERNAME: $PARTS"
done

# Secret Service D-Bus (org.freedesktop.secrets)
echo ""
echo "=== 8b. SECRET SERVICE (D-Bus) ==="
for USER_HOME in /home/*; do
  [ -d "$USER_HOME" ] || continue
  USERNAME=$(basename "$USER_HOME")
  id "$USERNAME" >/dev/null 2>&1 || continue
  UID_NUM=$(id -u "$USERNAME")
  [ -S "/run/user/$UID_NUM/bus" ] || continue
  SECRETS=$(sudo -u "$USERNAME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_NUM/bus" \
    busctl --user list 2>/dev/null | grep "org.freedesktop.secrets")
  if [ -n "$SECRETS" ]; then
    echo "  $USERNAME: org.freedesktop.secrets DISPONÍVEL"
    # Testar gravação/leitura
    if command -v secret-tool >/dev/null 2>&1; then
      if sudo -u "$USERNAME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_NUM/bus" \
        XDG_RUNTIME_DIR="/run/user/$UID_NUM" \
        secret-tool store --label='diag-test' app intune-diag <<< "ok" 2>/dev/null; then
        RESULT=$(sudo -u "$USERNAME" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_NUM/bus" \
          XDG_RUNTIME_DIR="/run/user/$UID_NUM" \
          secret-tool lookup app intune-diag 2>/dev/null)
        [ "$RESULT" = "ok" ] && echo "    secret-tool: FUNCIONAL" || echo "    secret-tool: FALHOU na leitura"
      else
        echo "    secret-tool: FALHOU na gravação (keyring bloqueada?)"
      fi
    fi
  else
    echo "  $USERNAME: org.freedesktop.secrets NÃO DISPONÍVEL"
  fi
done

# --- 9. Logs relevantes (últimos erros) ---
echo ""
echo "=== 9. LOGS RECENTES ==="
echo "  --- gkr-pam (últimas 5 linhas) ---"
journalctl -b --no-pager -g "gkr-pam" 2>/dev/null | tail -5 | sed 's/^/      /' || echo "      (sem logs)"
echo "  --- intune (últimas 5 linhas) ---"
journalctl -b --no-pager -u intune-daemon 2>/dev/null | tail -5 | sed 's/^/      /' || echo "      (sem logs)"
echo "  --- gnome-keyring (últimas 5 linhas) ---"
journalctl -b --no-pager -g "gnome-keyring" 2>/dev/null | tail -5 | sed 's/^/      /' || echo "      (sem logs)"

echo ""
echo "========================================"
echo " FIM DO DIAGNÓSTICO"
echo "========================================"
