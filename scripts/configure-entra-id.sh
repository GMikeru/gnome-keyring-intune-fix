#!/bin/bash
# ============================================================
# CONFIGURAR ENTRA ID (AUTHD) NO UBUNTU (22.04 a 26.04)
# Executar como root (sudo)
# ============================================================

# --- 0. Verificar root ---
if [ "$EUID" -ne 0 ]; then
  echo "ERRO: Este script precisa ser executado como root (sudo)."
  exit 1
fi

# --- 1. Instalar authd ---
if ! dpkg -l | grep -qw authd; then
  add-apt-repository -y ppa:ubuntu-enterprise-desktop/authd >/dev/null 2>&1
  apt-get update -qq
  apt-get install -y authd
  echo "OK: authd instalado"
else
  echo "OK: authd já instalado"
fi

# --- 2. Login timeout ---
if ! grep -q "LOGIN_TIMEOUT.*360" /etc/login.defs; then
  sed -i 's/^\(LOGIN_TIMEOUT\t\t\)[0-9]\+/\1360/' /etc/login.defs
  echo "OK: LOGIN_TIMEOUT ajustado para 360"
else
  echo "OK: LOGIN_TIMEOUT já configurado"
fi

# --- 3. SSH para authd ---
mkdir -p /etc/ssh/sshd_config.d
if [ ! -f /etc/ssh/sshd_config.d/authd.conf ] || ! grep -q "UsePAM yes" /etc/ssh/sshd_config.d/authd.conf 2>/dev/null; then
  printf 'UsePAM yes\nKbdInteractiveAuthentication yes\n' > /etc/ssh/sshd_config.d/authd.conf
  echo "OK: SSH configurado para authd"
else
  echo "OK: SSH já configurado"
fi

systemctl is-enabled --quiet authd 2>/dev/null || systemctl enable authd >/dev/null 2>&1

# --- 4. Snap authd-msentraid ---
if ! snap list 2>/dev/null | grep -qw authd-msentraid; then
  snap wait system seed.loaded || true
  snap install authd-msentraid
  echo "OK: snap authd-msentraid instalado"
else
  echo "OK: snap authd-msentraid já instalado"
fi

# --- 5. Broker config ---
mkdir -p /etc/authd/brokers.d
if [ ! -f /etc/authd/brokers.d/msentraid.conf ]; then
  for i in $(seq 1 30); do
    [ -f /snap/authd-msentraid/current/conf/authd/msentraid.conf ] && cp /snap/authd-msentraid/current/conf/authd/msentraid.conf /etc/authd/brokers.d/msentraid.conf && break
    sleep 2
  done
  echo "OK: broker msentraid.conf copiado"
else
  echo "OK: broker msentraid.conf já existe"
fi

# --- 6. Tenant ID / Client ID / Permissões ---
# ============================================================
# IMPORTANT: Replace the placeholder values below with your
# organization's Azure AD / Entra ID configuration:
#   YOUR_CLIENT_ID  → App Registration Client ID from Azure Portal
#   YOUR_ISSUER_ID  → Your Azure AD Tenant ID (Directory ID)
#   @yourdomain.com → Your organization's email domain suffix
# ============================================================
YOUR_CLIENT_ID="<YOUR_CLIENT_ID>"       # e.g. "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
YOUR_ISSUER_ID="<YOUR_ISSUER_ID>"       # e.g. "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
YOUR_DOMAIN_SUFFIX="@yourdomain.com"    # e.g. "@contoso.com"

BROKER_CONF="/var/snap/authd-msentraid/current/broker.conf"
if [ -f "$BROKER_CONF" ]; then
  if echo "$YOUR_CLIENT_ID" | grep -q "YOUR_CLIENT_ID"; then
    echo "ERRO: Edite este script e substitua YOUR_CLIENT_ID pelo Client ID da sua organização."
    exit 1
  fi
  grep -q "<CLIENT_ID>" "$BROKER_CONF" && sed -i "s|<CLIENT_ID>|${YOUR_CLIENT_ID}|g" "$BROKER_CONF" && echo "OK: CLIENT_ID configurado"
  grep -q "<ISSUER_ID>" "$BROKER_CONF" && sed -i "s|<ISSUER_ID>|${YOUR_ISSUER_ID}|g" "$BROKER_CONF" && echo "OK: ISSUER_ID configurado"
  if ! grep -q "^allowed_users = ALL" "$BROKER_CONF"; then
    sed -i '/^allowed_users/d' "$BROKER_CONF"
    echo 'allowed_users = ALL' >> "$BROKER_CONF"
    echo "OK: allowed_users configurado"
  fi
  if ! grep -q "^ssh_allowed_suffixes = ${YOUR_DOMAIN_SUFFIX}" "$BROKER_CONF"; then
    sed -i '/^ssh_allowed_suffixes/d' "$BROKER_CONF"
    echo "ssh_allowed_suffixes = ${YOUR_DOMAIN_SUFFIX}" >> "$BROKER_CONF"
    echo "OK: ssh_allowed_suffixes configurado"
  fi
else
  echo "ERRO: $BROKER_CONF não encontrado"
fi

# --- 7. Reiniciar serviços ---
snap restart authd-msentraid 2>/dev/null || true
systemctl restart authd 2>/dev/null || true
systemctl restart ssh 2>/dev/null || true
echo "OK: Entra ID configurado!"

# ============================================================
# VALIDAÇÃO
# ============================================================
echo ""
echo "=== VALIDAÇÃO ==="
dpkg -l authd | grep "^ii" || echo "authd não encontrado por dpkg"
snap list authd-msentraid || echo "snap authd-msentraid não encontrado"
[ -f /etc/authd/brokers.d/msentraid.conf ] && echo "OK: /etc/authd/brokers.d/msentraid.conf existe" || echo "ERRO: /etc/authd/brokers.d/msentraid.conf não existe"
[ -f /var/snap/authd-msentraid/current/broker.conf ] && echo "OK: /var/snap/authd-msentraid/current/broker.conf existe" || echo "ERRO: /var/snap/authd-msentraid/current/broker.conf não existe"
[ -f /etc/ssh/sshd_config.d/authd.conf ] && echo "OK: /etc/ssh/sshd_config.d/authd.conf existe" || echo "ERRO: /etc/ssh/sshd_config.d/authd.conf não existe"
systemctl is-active authd --quiet && echo "OK: authd está ativo" || echo "ERRO: authd está inativo"
snap services authd-msentraid 2>/dev/null || echo "Não foi possível listar serviços snap"
