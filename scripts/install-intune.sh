#!/bin/bash
# ============================================================
# INSTALAR MICROSOFT INTUNE NO UBUNTU (22.04 a 26.04)
# Executar como root (sudo)
# ============================================================

# --- 0. Verificar root ---
if [ "$EUID" -ne 0 ]; then
  echo "ERRO: Este script precisa ser executado como root (sudo)."
  exit 1
fi

# --- 1. Chaves GPG Microsoft ---
if [ ! -f /usr/share/keyrings/microsoft.gpg ]; then
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg
  chmod 644 /usr/share/keyrings/microsoft.gpg
  echo "OK: microsoft.gpg importada"
else
  echo "OK: microsoft.gpg já existe"
fi

if ! gpg --no-default-keyring --keyring /usr/share/keyrings/microsoft-2025.gpg --list-keys 2>/dev/null | grep -qi "EB3E94ADBE1229CF"; then
  tmpdir=$(mktemp -d)
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc -o "$tmpdir/ms.asc"
  curl -fsSL https://packages.microsoft.com/keys/microsoft-2025.asc -o "$tmpdir/ms2025.asc"
  gpg --no-default-keyring --keyring "$tmpdir/combined.gpg" --import "$tmpdir/ms.asc" 2>/dev/null
  gpg --no-default-keyring --keyring "$tmpdir/combined.gpg" --import "$tmpdir/ms2025.asc" 2>/dev/null
  cp "$tmpdir/combined.gpg" /usr/share/keyrings/microsoft-2025.gpg
  chmod 644 /usr/share/keyrings/microsoft-2025.gpg
  rm -rf "$tmpdir"
  echo "OK: microsoft-2025.gpg importada"
else
  echo "OK: microsoft-2025.gpg já existe"
fi

# --- 2. Repositórios APT ---
. /etc/os-release
EDGE_LIST="/etc/apt/sources.list.d/microsoft-edge.list"
EDGE_EXPECTED="deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main"
if [ ! -f "$EDGE_LIST" ] || ! grep -qF "$EDGE_EXPECTED" "$EDGE_LIST" 2>/dev/null; then
  echo "$EDGE_EXPECTED" > "$EDGE_LIST"
  echo "OK: repo Edge configurado"
else
  echo "OK: repo Edge já existe"
fi

PROD_LIST="/etc/apt/sources.list.d/microsoft-prod.list"
PROD_EXPECTED="deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-2025.gpg] https://packages.microsoft.com/ubuntu/${VERSION_ID}/prod ${VERSION_CODENAME} main"
if [ ! -f "$PROD_LIST" ] || ! grep -qF "$PROD_EXPECTED" "$PROD_LIST" 2>/dev/null; then
  echo "$PROD_EXPECTED" > "$PROD_LIST"
  echo "OK: repo Prod configurado"
else
  echo "OK: repo Prod já existe"
fi

# --- 3. Instalar pacotes ---
sleep 5
apt-get update -qq 2>&1 || true
dpkg -l microsoft-edge-stable 2>/dev/null | grep -q "^ii" || apt-get install -y microsoft-edge-stable
rm -f /etc/apt/sources.list.d/microsoft-edge-*.list
echo "$EDGE_EXPECTED" > "$EDGE_LIST"
dpkg -l intune-portal 2>/dev/null | grep -q "^ii" || apt-get install -y intune-portal

# --- 4. Sudoers ---
if [ ! -f /etc/sudoers.d/intune-nopasswd ] || ! grep -q "intune-portal ALL=(ALL) NOPASSWD: ALL" /etc/sudoers.d/intune-nopasswd 2>/dev/null; then
  printf 'intune-portal ALL=(ALL) NOPASSWD: ALL\nintune-agent ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/intune-nopasswd
  chmod 440 /etc/sudoers.d/intune-nopasswd
  echo "OK: sudoers configurado"
else
  echo "OK: sudoers já existe"
fi

# --- 5. Polkit PKLA (Ubuntu 22.04 legado) ---
if [ ! -f /etc/polkit-1/localauthority/50-local.d/10-intune-elevation.pkla ]; then
  mkdir -p /etc/polkit-1/localauthority/50-local.d
  cat << 'EOF' > /etc/polkit-1/localauthority/50-local.d/10-intune-elevation.pkla
[Allow Intune to elevate without password]
Identity=unix-user:intune-portal;unix-user:intune-agent
Action=*
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF
  echo "OK: Polkit PKLA criado"
else
  echo "OK: Polkit PKLA já existe"
fi

# --- 6. Polkit Rules JS (Ubuntu 24.04+) ---
if [ ! -f /etc/polkit-1/rules.d/10-intune-admin.rules ]; then
  mkdir -p /etc/polkit-1/rules.d
  cat << 'EOF' > /etc/polkit-1/rules.d/10-intune-admin.rules
polkit.addRule(function(action, subject) {
    if (subject.user === "intune-portal" || subject.user === "intune-agent" || subject.user === "root") return polkit.Result.YES;
    if (action.id.indexOf("com.microsoft.intune") >= 0) return polkit.Result.YES;
});
EOF
  echo "OK: Polkit Rules JS criado"
else
  echo "OK: Polkit Rules JS já existe"
fi

# --- 7. Override systemd intune-daemon ---
if [ ! -f /etc/systemd/system/intune-daemon.service.d/no-auth-prompt.conf ]; then
  mkdir -p /etc/systemd/system/intune-daemon.service.d
  cat << 'EOF' > /etc/systemd/system/intune-daemon.service.d/no-auth-prompt.conf
[Service]
Environment=SUDO_ASKPASS=/bin/true
Environment=DEBIAN_FRONTEND=noninteractive
EOF
  echo "OK: override intune-daemon criado"
else
  echo "OK: override intune-daemon já existe"
fi

# --- 8. Timer de sync (a cada 1h) ---
if [ ! -f /usr/lib/systemd/user/intune-sync.service ]; then
  mkdir -p /usr/lib/systemd/user
  cat << 'EOF' > /usr/lib/systemd/user/intune-sync.service
[Unit]
Description=Forcar Sync do Intune Agent
[Service]
Type=oneshot
ExecStart=/opt/microsoft/intune/bin/intune-agent
EOF
  cat << 'EOF' > /usr/lib/systemd/user/intune-sync.timer
[Unit]
Description=Sincroniza Intune a cada hora
[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
EOF
  systemctl --global enable intune-sync.timer 2>/dev/null || true
  echo "OK: timer intune-sync criado"
else
  echo "OK: timer intune-sync já existe"
fi

# --- 9. GNOME Keyring (login.keyring sem senha para Intune + Entra ID) ---
apt-get install -y python3-secretstorage libsecret-tools 2>/dev/null || true

# Remover script legado de perfil que pode gerar arquivos de keyring corrompidos no shell startup
if [ -f "/etc/profile.d/unlock-keyring.sh" ]; then
  rm -f "/etc/profile.d/unlock-keyring.sh"
  echo "OK: Script legado /etc/profile.d/unlock-keyring.sh removido"
fi

# Limpar keyrings problemáticos e configurar alias default
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

# --- 9c. Remover autostart de criação legado (obsoleto devido à escrita direta do INI) ---
# Isso garante que nenhum prompt de criação de chaveiro GUI seja disparado nas máquinas
rm -f /etc/xdg/autostart/create-keyring-intune.desktop
rm -f /usr/local/bin/intune-create-keyring.sh
rm -f /etc/sudoers.d/intune-keyring-autostart

# Autostart: DESBLOQUEAR keyring em todo login (para Entra ID)
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
NoDisplay=true
EOF
  chmod 644 "$AUTOSTART_UNLOCK"
  echo "OK: autostart de DESBLOQUEIO da keyring criado"
else
  echo "OK: autostart de desbloqueio já existe"
fi

# --- 9b. Criar serviço SYSTEMD USER global para DESBLOQUEIO PRECOCE da keyring ---
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

# Tentar desbloquear agora para usuários que já têm keyring funcional
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

# --- 10. Aplicar alterações ---
systemctl daemon-reload
systemctl restart polkit 2>/dev/null || true
systemctl restart intune-daemon 2>/dev/null || true
echo "OK: Intune instalado e configurado!"

# ============================================================
# VALIDAÇÃO
# ============================================================
echo ""
echo "=== VALIDAÇÃO ==="
ls -la /usr/share/keyrings/microsoft*.gpg || echo "Chaves GPG não encontradas"
[ -f /etc/apt/sources.list.d/microsoft-edge.list ] && echo "OK: Microsoft Edge Repo existe" || echo "ERRO: Microsoft Edge Repo não existe"
[ -f /etc/apt/sources.list.d/microsoft-prod.list ] && echo "OK: Microsoft Prod Repo existe" || echo "ERRO: Microsoft Prod Repo não existe"
dpkg -l intune-portal microsoft-edge-stable | grep "^ii" || echo "Pacotes intune-portal ou edge-stable não instalados"
cat /etc/sudoers.d/intune-nopasswd 2>/dev/null || echo "Sudoers intune-nopasswd não encontrado"
cat /etc/polkit-1/localauthority/50-local.d/10-intune-elevation.pkla 2>/dev/null || echo "PKLA não encontrado"
cat /etc/polkit-1/rules.d/10-intune-admin.rules 2>/dev/null || echo "Polkit JS rules não encontrado"
systemctl is-active intune-daemon --quiet && echo "OK: intune-daemon está ativo" || echo "ERRO: intune-daemon está inativo"
systemctl --global list-timers | grep -q intune-sync && echo "OK: Timer intune-sync encontrado" || echo "ERRO: Timer intune-sync não encontrado"
