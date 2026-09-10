#!/bin/bash
# ============================================================
# CRIAR GNOME KEYRING SEM SENHA (TEXT-BASED INI)
# Executar como usuário local (sem sudo) na sessão do usuário
# ============================================================

KDIR="$HOME/.local/share/keyrings"
KFILE="$KDIR/login.keyring"

echo "=========================================="
echo " INICIALIZADOR AUTOMÁTICO DE KEYRING (INI)"
echo "=========================================="

# 1. Garantir que o diretório existe
mkdir -p "$KDIR"
chmod 700 "$KDIR"

# 2. Backup se já existir
if [ -f "$KFILE" ]; then
  BACKUP_FILE="${KFILE}.bak_$(date +%Y%m%d_%H%M%S)"
  mv "$KFILE" "$BACKUP_FILE"
  echo "AVISO: Keyring antiga movida para $BACKUP_FILE"
fi

# 3. Escrever o cabeçalho INI de texto puro do GNOME Keyring sem senha
cat << 'EOF' > "$KFILE"
[keyring]
display-name=login
ctime=1789066652
mtime=0
lock-on-idle=false
lock-after=false
EOF

# 4. Ajustar permissões para segurança (apenas o usuário lê/escreve)
chmod 600 "$KFILE"
echo "OK: Nova login.keyring (formato de texto INI limpo) criada em $KFILE"

# 5. Forçar o daemon a recarregar e desbloquear a keyring
echo "Info: Enviando sinal de desbloqueio automático para o daemon..."
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID/bus"
printf "\0" | gnome-keyring-daemon --unlock 2>/dev/null

echo "=========================================="
echo " CONFIGURAÇÃO CONCLUÍDA COM SUCESSO!"
echo " Agora você pode abrir o Company Portal do Intune."
echo "=========================================="
