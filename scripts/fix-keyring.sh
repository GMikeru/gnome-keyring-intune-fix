#!/bin/bash
# ============================================================
# CORRIGIR GNOME KEYRING PARA INTUNE (login.keyring sem senha)
# Executar como root (sudo)
# Compatível com Ubuntu 24.04+ e Entra ID (authd)
# ============================================================

# --- 0. Verificar root ---
if [ "$EUID" -ne 0 ]; then
  echo "ERRO: Este script precisa ser executado como root (sudo)."
  exit 1
fi

# --- 0. Verificar pré-requisitos ---
if ! command -v gnome-keyring-daemon >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y gnome-keyring 2>/dev/null || true
fi
apt-get install -y python3-secretstorage libsecret-tools 2>/dev/null || true

# Remover script legado de perfil que pode gerar arquivos de keyring corrompidos no shell startup
if [ -f "/etc/profile.d/unlock-keyring.sh" ]; then
  rm -f "/etc/profile.d/unlock-keyring.sh"
  echo "OK: Script legado /etc/profile.d/unlock-keyring.sh removido"
fi

# --- 1. Limpar keyrings problemáticos e configurar alias default ---
for USER_HOME in /home/*; do
  [ -d "$USER_HOME" ] || continue
  
  # Obter o nome do usuário e UID diretamente do dono do diretório home (100% offline, imune a timeouts de SSSD/Entra ID)
  USERNAME=$(stat -c '%U' "$USER_HOME" 2>/dev/null)
  UID_NUM=$(stat -c '%u' "$USER_HOME" 2>/dev/null)

  # Fallback seguro se o stat falhar
  if [ -z "$USERNAME" ] || [ "$USERNAME" = "UNKNOWN" ] || [ -z "$UID_NUM" ]; then
    USERNAME=$(basename "$USER_HOME")
    id "$USERNAME" >/dev/null 2>&1 || continue
    UID_NUM=$(id -u "$USERNAME")
  fi

  KDIR="$USER_HOME/.local/share/keyrings"
  mkdir -p "$KDIR"

  # Verificar e corrigir o arquivo login.keyring
  KFILE="$KDIR/login.keyring"
  if [ -f "$KFILE" ]; then
    # Verificar se o keyring está em texto limpo (unencrypted) ou criptografado (binary)
    if head -n 1 "$KFILE" 2>/dev/null | grep -q "^\[keyring\]"; then
      echo "OK: $USERNAME já tem login.keyring em texto puro (preservando chaves existentes de outros apps)"
    else
      # Se for binário, precisamos mover/apagar porque o authd/Intune não conseguiria desbloquear sem prompt
      BACKUP_FILE="${KFILE}.bak_$(date +%Y%m%d_%H%M%S)"
      mv "$KFILE" "$BACKUP_FILE"
      echo "AVISO: $USERNAME login.keyring criptografado (binário) movido para backup: $BACKUP_FILE"
      
      # Escrever a nova keyring em texto puro
      cat << 'EOF' > "$KFILE"
[keyring]
display-name=login
ctime=1789066652
mtime=0
lock-on-idle=false
lock-after=false
EOF
      echo "OK: $USERNAME — Nova login.keyring limpa criada em texto puro"
    fi
  else
    # Se não existe, criamos a de texto puro
    cat << 'EOF' > "$KFILE"
[keyring]
display-name=login
ctime=1789066652
mtime=0
lock-on-idle=false
lock-after=false
EOF
    echo "OK: $USERNAME — login.keyring de texto puro inicializada"
  fi

  # Se o arquivo user.keystore existir, ele pode travar todo o fluxo do Secret Service
  # pois o daemon tenta desbloqueá-lo como master keystore e falha (visto que o authd não passa a senha).
  # Vamos movê-lo para backup para desbloquear a API.
  UKEYSTORE="$KDIR/user.keystore"
  if [ -f "$UKEYSTORE" ]; then
    BACKUP_KEYSTORE="${UKEYSTORE}.bak_$(date +%Y%m%d_%H%M%S)"
    mv "$UKEYSTORE" "$BACKUP_KEYSTORE"
    echo "AVISO: $USERNAME — user.keystore master encontrado e movido para backup: $BACKUP_KEYSTORE"
  fi

  # Remover outros chaveiros extras (exceto o login.keyring)
  for kf in "$KDIR"/*.keyring; do
    [ -f "$kf" ] || continue
    FNAME=$(basename "$kf")
    if [ "$FNAME" != "login.keyring" ]; then
      rm -f "$kf"
      echo "OK: $USERNAME — removido chaveiro extra $FNAME"
    fi
  done

  # Limpar TODAS as variações case-sensitive de default e login
  rm -f "$KDIR/default" "$KDIR/Default" "$KDIR/DEFAULT"
  rm -f "$KDIR/login" "$KDIR/Login" "$KDIR/LOGIN"

  # Mapear explicitamente o alias default para o keyring login (necessário para o Secret Service resolver)
  echo -n "login" > "$KDIR/default"
  echo "OK: $USERNAME — alias 'default' mapeado para 'login'"

  # Matar processos antigos/fantasmas para forçar o GNOME Keyring a ler as novas configurações do disco
  pkill -u "$UID_NUM" -x gnome-keyring-daemon 2>/dev/null || true
  pkill -u "$UID_NUM" -f gnome-keyring-daemon 2>/dev/null || true
  sleep 1

  # Ajustar permissões e dono
  chmod 700 "$KDIR"
  chmod 600 "$KFILE" 2>/dev/null || true
  chmod 600 "$KDIR/default" 2>/dev/null || true
  chown -R "$USERNAME":"$USERNAME" "$KDIR" 2>/dev/null || true
done

# --- 2. Limpar cache corrompido do Intune e broker ---
for USER_HOME in /home/*; do
  [ -d "$USER_HOME" ] || continue
  USERNAME=$(stat -c '%U' "$USER_HOME" 2>/dev/null)
  UID_NUM=$(stat -c '%u' "$USER_HOME" 2>/dev/null)
  if [ -z "$USERNAME" ] || [ "$USERNAME" = "UNKNOWN" ] || [ -z "$UID_NUM" ]; then
    USERNAME=$(basename "$USER_HOME")
    id "$USERNAME" >/dev/null 2>&1 || continue
    UID_NUM=$(id -u "$USERNAME")
  fi
  CLEANED=0

  for CACHE_DIR in \
    "$USER_HOME/.cache/intune-portal" \
    "$USER_HOME/.config/intune-portal" \
    "$USER_HOME/.config/microsoft-identity-broker" \
    "$USER_HOME/.local/state/microsoft-identity-broker"; do
    if [ -d "$CACHE_DIR" ]; then
      rm -rf "$CACHE_DIR"
      CLEANED=1
    fi
  done

  if [ "$CLEANED" -eq 1 ]; then
    echo "OK: $USERNAME — cache corrompido do Intune/broker limpo"
  fi
done

# --- 3. Verificar Secret Service via D-Bus ---
echo ""
echo "=== Verificação org.freedesktop.secrets ==="
for USER_HOME in /home/*; do
  [ -d "$USER_HOME" ] || continue
  USERNAME=$(stat -c '%U' "$USER_HOME" 2>/dev/null)
  UID_NUM=$(stat -c '%u' "$USER_HOME" 2>/dev/null)
  if [ -z "$USERNAME" ] || [ "$USERNAME" = "UNKNOWN" ] || [ -z "$UID_NUM" ]; then
    USERNAME=$(basename "$USER_HOME")
    id "$USERNAME" >/dev/null 2>&1 || continue
    UID_NUM=$(id -u "$USERNAME")
  fi

  if [ -S "/run/user/$UID_NUM/bus" ]; then
    SECRETS_OWNER=$(sudo -u "$USERNAME" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_NUM/bus" \
      busctl --user list 2>/dev/null | grep -i "org.freedesktop.secrets" | awk '{print $1}')
    if [ -n "$SECRETS_OWNER" ]; then
      echo "  $USERNAME: org.freedesktop.secrets DISPONÍVEL ($SECRETS_OWNER)"
    else
      echo "  $USERNAME: org.freedesktop.secrets NÃO DISPONÍVEL (Intune vai falhar!)"
    fi
  fi
done

# --- 4. Remover autostart de criação legado (obsoleto devido à escrita direta do INI) ---
# Isso garante que nenhum prompt de criação de chaveiro GUI seja disparado nas máquinas
rm -f /etc/xdg/autostart/create-keyring-intune.desktop
rm -f /usr/local/bin/intune-create-keyring.sh
rm -f /etc/sudoers.d/intune-keyring-autostart
echo "OK: Arquivos legados de autostart de criação removidos (desnecessários)"

# --- 5. Autostart: DESBLOQUEAR keyring nos logins seguintes ---
AUTOSTART_UNLOCK="/etc/xdg/autostart/unlock-keyring-intune.desktop"
if [ ! -f "$AUTOSTART_UNLOCK" ]; then
  mkdir -p /etc/xdg/autostart
  cat << 'EOF' > "$AUTOSTART_UNLOCK"
[Desktop Entry]
Type=Application
Name=Unlock Login Keyring for Intune
Comment=Desbloqueia keyring com senha vazia para Intune funcionar com Entra ID
Exec=/bin/sh -c 'printf "\0" | gnome-keyring-daemon --unlock'
X-GNOME-Autostart-Phase=Initialization
X-GNOME-AutoRestart=false
NoDisplay=true
EOF
  chmod 644 "$AUTOSTART_UNLOCK"
  echo "OK: autostart de DESBLOQUEIO da keyring instalado"
else
  echo "OK: autostart de desbloqueio já existe"
fi

# --- 5b. Criar serviço SYSTEMD USER global para DESBLOQUEIO PRECOCE da keyring ---
# Isso resolve a condição de corrida onde o microsoft-identity-broker inicializa
# ANTES do autostart do GNOME rodar, o que forçava a criação de "Default_Keyring.keyring".
SYSTEMD_USER_DIR="/etc/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

cat << 'EOF' > "$SYSTEMD_USER_DIR/unlock-keyring-intune.service"
[Unit]
Description=Unlock GNOME Keyring Early for Intune
After=gnome-keyring-daemon.service
BindsTo=gnome-keyring-daemon.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'printf "\0" | gnome-keyring-daemon --unlock'
Slice=session.slice

[Install]
WantedBy=default.target
EOF

chmod 644 "$SYSTEMD_USER_DIR/unlock-keyring-intune.service"
systemctl --global enable unlock-keyring-intune.service >/dev/null 2>&1 || true
echo "OK: Serviço SYSTEMD USER global de desbloqueio precoce instalado e ativado"

# --- 6. Tentar desbloquear agora (para usuários logados com keyring funcional) ---
for USER_HOME in /home/*; do
  [ -d "$USER_HOME" ] || continue
  USERNAME=$(stat -c '%U' "$USER_HOME" 2>/dev/null)
  UID_NUM=$(stat -c '%u' "$USER_HOME" 2>/dev/null)
  if [ -z "$USERNAME" ] || [ "$USERNAME" = "UNKNOWN" ] || [ -z "$UID_NUM" ]; then
    USERNAME=$(basename "$USER_HOME")
    id "$USERNAME" >/dev/null 2>&1 || continue
    UID_NUM=$(id -u "$USERNAME")
  fi
  KDIR="$USER_HOME/.local/share/keyrings"

  [ -f "$KDIR/login.keyring" ] || continue
  [ "$(stat -c%s "$KDIR/login.keyring" 2>/dev/null)" -gt 200 ] || continue
  pgrep -u "$UID_NUM" -f gnome-keyring-daemon >/dev/null 2>&1 || continue

  printf '\0' | sudo -u "$USERNAME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_NUM/bus" \
    XDG_RUNTIME_DIR="/run/user/$UID_NUM" \
    gnome-keyring-daemon --unlock 2>/dev/null
  echo "OK: $USERNAME — keyring desbloqueada"
done

# --- 7. Verificar resultado ---
echo ""
echo "=== Resultado ==="
for USER_HOME in /home/*; do
  [ -d "$USER_HOME" ] || continue
  USERNAME=$(stat -c '%U' "$USER_HOME" 2>/dev/null)
  UID_NUM=$(stat -c '%u' "$USER_HOME" 2>/dev/null)
  if [ -z "$USERNAME" ] || [ "$USERNAME" = "UNKNOWN" ] || [ -z "$UID_NUM" ]; then
    USERNAME=$(basename "$USER_HOME")
    id "$USERNAME" >/dev/null 2>&1 || continue
    UID_NUM=$(id -u "$USERNAME")
  fi
  KDIR="$USER_HOME/.local/share/keyrings"
  if [ -f "$KDIR/login.keyring" ]; then
    SIZE=$(stat -c%s "$KDIR/login.keyring" 2>/dev/null || echo "?")
    if [ "$SIZE" -gt 200 ] 2>/dev/null; then
      # Testar se a keyring está ativa de forma não-bloqueante via Python
      if [ -S "/run/user/$UID_NUM/bus" ] && pgrep -u "$UID_NUM" -f gnome-keyring-daemon >/dev/null 2>&1; then
        STATUS_INFO=$(sudo -u "$USERNAME" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_NUM/bus" python3 -c "
import secretstorage
try:
    conn = secretstorage.dbus_init()
    for col in secretstorage.get_all_collections(conn):
        if col.get_label().lower() == 'login':
            print('UNLOCKED' if not col.is_locked() else 'LOCKED')
            exit(0)
    print('NOT_FOUND')
except Exception as e:
    print('ERROR')
" 2>/dev/null)

        case "$STATUS_INFO" in
          UNLOCKED)
            echo "  $USERNAME: OK (${SIZE} bytes, Secret Service DESBLOQUEADO e funcional)"
            ;;
          LOCKED)
            echo "  $USERNAME: AVISO (${SIZE} bytes, keyring está BLOQUEADA — precisa de senha/desbloqueio)"
            ;;
          NOT_FOUND)
            echo "  $USERNAME: AVISO (${SIZE} bytes, keyring 'login' não encontrada no D-Bus)"
            ;;
          *)
            echo "  $USERNAME: OK (${SIZE} bytes, daemon ativo)"
            ;;
        esac
      else
        echo "  $USERNAME: OK (${SIZE} bytes, daemon não ativo para testar)"
      fi
    else
      echo "  $USERNAME: PARCIAL (${SIZE} bytes — precisa recriar)"
    fi
  else
    echo "  $USERNAME: PENDENTE (keyring será criada no próximo login)"
  fi
done
echo ""
[ -f "$AUTOSTART_UNLOCK" ] && echo "  Autostart unlock: ATIVO" || echo "  Autostart unlock: NÃO ENCONTRADO"
