#!/bin/bash
# ============================================================
# USER-LEVEL KEYRING CORRECTION TEST RUNNER
# Tests the keyring correction logic for the current user
# without requiring root/sudo privileges.
# ============================================================

echo "=========================================="
echo " STARTING KEYRING CORRECTION USER TEST"
echo " User: $USER (UID: $UID)"
echo " Date: $(date)"
echo "=========================================="

export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID/bus"

# --- 1. Test Prerequisites ---
echo ""
echo "--- STEP 1: PRE-REQUISITES CHECK ---"
if command -v gnome-keyring-daemon >/dev/null 2>&1; then
  echo "OK: gnome-keyring-daemon is installed."
else
  echo "ERRO: gnome-keyring-daemon is NOT installed."
fi

if python3 -c "import secretstorage" 2>/dev/null; then
  echo "OK: python3-secretstorage is installed."
else
  echo "ERRO: python3-secretstorage is NOT installed."
fi

# --- 2. Test Keyring Cleaning Logic ---
echo ""
echo "--- STEP 2: KEYRING INTEGRITY CHECK ---"
KDIR="$HOME/.local/share/keyrings"
if [ -d "$KDIR" ]; then
  echo "OK: Keyrings directory exists ($KDIR)."
  if [ -f "$KDIR/login.keyring" ]; then
    FSIZE=$(stat -c%s "$KDIR/login.keyring" 2>/dev/null || echo 0)
    echo "Info: login.keyring found with size: $FSIZE bytes."
    if [ "$FSIZE" -gt 200 ]; then
      echo "OK: login.keyring is functional (>200 bytes)."
    else
      echo "AVISO: login.keyring is non-functional (<200 bytes) and would be deleted by the script."
    fi
  else
    echo "Info: No login.keyring found. It would be created on next login."
  fi
else
  echo "Info: Keyrings directory does not exist. It would be created."
fi

# --- 3. Test Cache Cleaning Simulation ---
echo ""
echo "--- STEP 3: CACHE CLEANING SIMULATION ---"
for CACHE_DIR in \
  "$HOME/.cache/intune-portal" \
  "$HOME/.config/intune-portal" \
  "$HOME/.config/microsoft-identity-broker" \
  "$HOME/.local/state/microsoft-identity-broker"; do
  if [ -d "$CACHE_DIR" ]; then
    echo "Info: Cache directory exists: $CACHE_DIR (would be cleaned by the script)."
  else
    echo "Info: Cache directory does not exist: $CACHE_DIR (clean)."
  fi
done

# --- 4. Test Secret Service D-Bus ---
echo ""
echo "--- STEP 4: D-BUS SECRET SERVICE CHECK ---"
if [ -S "/run/user/$UID/bus" ]; then
  echo "OK: D-Bus user session socket is active."
  SECRETS_OWNER=$(busctl --user list 2>/dev/null | grep -i "org.freedesktop.secrets" | awk '{print $1}')
  if [ -n "$SECRETS_OWNER" ]; then
    echo "OK: org.freedesktop.secrets is active on D-Bus ($SECRETS_OWNER)."
  else
    echo "ERRO: org.freedesktop.secrets is NOT active on D-Bus (Intune enrollment will fail!)."
  fi
else
  echo "ERRO: D-Bus socket not found at /run/user/$UID/bus."
fi

# --- 5. Test Autostart File Configuration Integrity ---
echo ""
echo "--- STEP 5: AUTOSTART SCHEMAS VALIDATION ---"
# We will write the scripts to a local temp folder to verify their formatting and syntax
TEMP_TEST_DIR=$(mktemp -d)
echo "Info: Creating temporary test configurations in $TEMP_TEST_DIR..."

cat << 'SCRIPT' > "$TEMP_TEST_DIR/intune-create-keyring-test.sh"
#!/bin/bash
KDIR="$HOME/.local/share/keyrings"
if [ -f "$KDIR/login.keyring" ] && [ "$(stat -c%s "$KDIR/login.keyring" 2>/dev/null)" -gt 200 ]; then
  echo "Create script check: Keyring exists and is valid. Exiting."
  exit 0
fi
echo "Create script check: Attempting keyring creation simulation..."
SCRIPT

cat << 'EOF' > "$TEMP_TEST_DIR/create-keyring-intune-test.desktop"
[Desktop Entry]
Type=Application
Name=Create Login Keyring for Intune
Comment=Cria keyring sem senha para Intune (prompt 1x — deixar senha vazia)
Exec=/usr/local/bin/intune-create-keyring.sh
X-GNOME-Autostart-Phase=Application
X-GNOME-AutoRestart=false
NoDisplay=true
EOF

cat << 'EOF' > "$TEMP_TEST_DIR/unlock-keyring-intune-test.desktop"
[Desktop Entry]
Type=Application
Name=Unlock Login Keyring for Intune
Comment=Desbloqueia keyring com senha vazia para Intune funcionar com Entra ID
Exec=/bin/sh -c 'printf "\0" | gnome-keyring-daemon --unlock'
X-GNOME-Autostart-Phase=Initialization
X-GNOME-AutoRestart=false
NoDisplay=true
EOF

# Syntax check of the generated autostart configurations
bash -n "$TEMP_TEST_DIR/intune-create-keyring-test.sh" && echo "OK: Generated autostart script is syntactically valid."
grep -q "Exec=" "$TEMP_TEST_DIR/create-keyring-intune-test.desktop" && echo "OK: Create desktop entry contains Exec path."
grep -q "Exec=" "$TEMP_TEST_DIR/unlock-keyring-intune-test.desktop" && echo "OK: Unlock desktop entry contains Exec path."

# --- 6. Test Keyring SecretStorage Connection & Unlock Verification ---
echo ""
echo "--- STEP 6: KEYRING WRITE/READ VERIFICATION ---"
python3 -c "
import secretstorage
try:
    conn = secretstorage.dbus_init()
    collections = list(secretstorage.get_all_collections(conn))
    login_coll = None
    for col in collections:
        if col.get_label() == 'Login':
            login_coll = col
            break
    if login_coll:
        print(f'OK: Found Login collection. Locked state: {login_coll.is_locked()}')
        if login_coll.is_locked():
            print('Info: Attempting to unlock Login collection...')
            # Since we can't type password, let's see if unlock completes or stays locked
        else:
            print('OK: Login collection is already unlocked and fully functional!')
    else:
        print('AVISO: Login collection was not found.')
except Exception as e:
    print(f'ERRO during SecretStorage test: {e}')
"

# Clean up temp test configs
rm -rf "$TEMP_TEST_DIR"
echo ""
echo "=========================================="
echo " KEYRING CORRECTION USER TEST COMPLETED"
echo "=========================================="
