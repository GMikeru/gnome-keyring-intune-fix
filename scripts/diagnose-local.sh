#!/bin/bash
# ============================================================
# DIAGNÓSTICO PROFUNDO LOCAL - GNOME KEYRING + INTUNE
# Executar como root (sudo) na máquina de teste com erro
# ============================================================

# --- 0. Verificar root ---
if [ "$EUID" -ne 0 ]; then
  echo "ERRO: Este script precisa ser executado como root (sudo)."
  exit 1
fi

echo "=========================================="
echo " INICIANDO DIAGNÓSTICO PROFUNDO LOCAL"
echo " Data: $(date)"
echo " Hostname: $(hostname)"
echo "=========================================="

# --- 1. Identificar Usuários ---
echo ""
echo "=== 1. USUÁRIOS E SESSOÕES EM HOME ==="
for USER_HOME in /home/*; do
  [ -d "$USER_HOME" ] || continue
  USERNAME=$(stat -c '%U' "$USER_HOME" 2>/dev/null)
  UID_NUM=$(stat -c '%u' "$USER_HOME" 2>/dev/null)
  
  if [ -z "$USERNAME" ] || [ "$USERNAME" = "UNKNOWN" ] || [ -z "$UID_NUM" ]; then
    USERNAME=$(basename "$USER_HOME")
    UID_NUM=$(id -u "$USERNAME" 2>/dev/null)
  fi
  
  [ -n "$UID_NUM" ] || continue
  
  echo "  - Usuário: $USERNAME (UID: $UID_NUM)"
  echo "    Home: $USER_HOME"
  
  # Verificar se a sessão D-Bus está ativa
  DBUS_SOCKET="/run/user/$UID_NUM/bus"
  if [ -S "$DBUS_SOCKET" ]; then
    echo "    D-Bus Socket: ATIVO ($DBUS_SOCKET)"
  else
    echo "    D-Bus Socket: INATIVO (O usuário está deslogado ou sem sessão gráfica ativa)"
  fi
  
  # Verificar daemon gnome-keyring
  DAEMON_PIDS=$(pgrep -u "$UID_NUM" -f gnome-keyring-daemon)
  if [ -n "$DAEMON_PIDS" ]; then
    echo "    gnome-keyring-daemon: ATIVO (PIDs: $(echo $DAEMON_PIDS | tr '\n' ' '))"
  else
    echo "    gnome-keyring-daemon: INATIVO"
  fi
done

# --- 2. Analisar Pasta de Keyrings do usuário de teste ---
echo ""
echo "=== 2. ANALISANDO ARQUIVOS DE KEYRING DO USUÁRIO ==="
# Detect the first user with an active GNOME session, or fallback to first user in /home
TEST_USER=""
for USER_HOME in /home/*; do
  [ -d "$USER_HOME" ] || continue
  U=$(stat -c '%U' "$USER_HOME" 2>/dev/null)
  [ -z "$U" ] || [ "$U" = "UNKNOWN" ] && U=$(basename "$USER_HOME")
  U_UID=$(stat -c '%u' "$USER_HOME" 2>/dev/null)
  if pgrep -u "$U_UID" -f gnome-keyring-daemon >/dev/null 2>&1; then
    TEST_USER="$U"
    break
  fi
  [ -z "$TEST_USER" ] && TEST_USER="$U"  # fallback to first user found
done

if [ -z "$TEST_USER" ]; then
  echo "AVISO: Nenhum usuário encontrado em /home/*"
else
  KDIR="/home/$TEST_USER/.local/share/keyrings"
  echo "Usuário identificado: $TEST_USER"
  echo "Caminho da pasta: $KDIR"
  
  if [ -d "$KDIR" ]; then
    echo "Conteúdo detalhado da pasta de keyrings:"
    ls -la "$KDIR"
    
    echo ""
    echo "--- Conteúdo de '$KDIR/default' ---"
    if [ -f "$KDIR/default" ]; then
      cat "$KDIR/default"
      echo ""
    else
      echo "Arquivo 'default' NÃO ENCONTRADO!"
    fi
    
    echo ""
    echo "--- Cabeçalho de '$KDIR/login.keyring' ---"
    if [ -f "$KDIR/login.keyring" ]; then
      # Exibir primeiras 15 linhas (ocultando segredos para segurança)
      head -n 15 "$KDIR/login.keyring"
    else
      echo "Arquivo 'login.keyring' NÃO ENCONTRADO!"
    fi
  else
    echo "Diretório de keyrings NÃO EXISTE em $KDIR!"
  fi
fi

# --- 3. Teste Programático de D-Bus e SecretStorage com Erros Abertos ---
echo ""
echo "=== 3. TESTE PROGRAMÁTICO DE CONEXÃO D-BUS (PYTHON) ==="
if [ -n "$TEST_USER" ]; then
  UID_NUM=$(id -u "$TEST_USER" 2>/dev/null || stat -c '%u' "/home/$TEST_USER")
  DBUS_SOCKET="/run/user/$UID_NUM/bus"
  
  if [ -S "$DBUS_SOCKET" ]; then
    echo "Executando teste D-Bus como usuário $TEST_USER..."
    
    sudo -u "$TEST_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=$DBUS_SOCKET" python3 - << 'EOF'
import sys
import traceback

print("1. Tentando importar secretstorage e conectar ao D-Bus...")
try:
    import secretstorage
    conn = secretstorage.dbus_init()
    print("   CONECTADO COM SUCESSO!")
except Exception as e:
    print("\n[ERRO] Falha ao inicializar o secretstorage ou D-Bus:")
    traceback.print_exc()
    sys.exit(1)

print("\n2. Tentando listar coleções (keyrings) ativas...")
try:
    collections = list(secretstorage.get_all_collections(conn))
    print(f"   Encontradas {len(collections)} coleções:")
    for col in collections:
        print(f"     - Coleção: '{col.get_label()}' | Caminho: '{col.collection_path}' | Bloqueada: {col.is_locked()}")
except Exception as e:
    print("\n[ERRO] Falha ao obter as coleções do Secret Service:")
    traceback.print_exc()
    sys.exit(1)

print("\n3. Tentando testar gravação e leitura de segredo diagnóstico...")
try:
    # Buscar a coleção padrão
    default_col = None
    for col in collections:
        if col.get_label().lower() == 'login':
            default_col = col
            break
    
    if default_col:
        print(f"   Coleção 'login' encontrada. Estado de bloqueio: {default_col.is_locked()}")
        print("   Tentando gravar item de teste temporário...")
        item = default_col.create_item("DiagTestItem", {"diag": "1"}, b"diagnostico_ok")
        print("   ITEM DIAGNÓSTICO GRAVADO COM SUCESSO!")
        
        # Ler de volta
        secret = item.get_secret()
        print(f"   Leitura de volta bem-sucedida! Segredo: {secret.decode('utf-8')}")
        
        # Deletar o item de teste para limpar o chaveiro
        item.delete()
        print("   Item diagnóstico limpo com sucesso.")
    else:
        print("   [AVISO] Nenhuma coleção chamada 'login' ou 'default' encontrada ativa no D-Bus!")
except Exception as e:
    print("\n[ERRO] Falha na gravação ou leitura do Secret Service:")
    traceback.print_exc()
EOF
  else
    echo "Aviso: D-Bus socket $DBUS_SOCKET inativo ou inexistente. Não é possível rodar teste de D-Bus."
  fi
fi

# --- 4. Logs Recentes do Sistema ---
echo ""
echo "=== 4. LOGS DE DIAGNÓSTICO (GNOME-KEYRING / BROKER) ==="
echo "--- Últimas 10 linhas de gnome-keyring ---"
journalctl -b --no-pager -g "gnome-keyring" 2>/dev/null | tail -10 || echo "Sem logs"

echo ""
echo "--- Últimas 10 linhas de microsoft-identity-broker (ou broker) ---"
journalctl -b --no-pager -g "microsoft-identity-broker" 2>/dev/null | tail -10 || journalctl -b --no-pager -g "broker" 2>/dev/null | tail -10 || echo "Sem logs"

echo "=========================================="
echo " DIAGNÓSTICO PROFUNDO LOCAL CONCLUÍDO"
echo "=========================================="
