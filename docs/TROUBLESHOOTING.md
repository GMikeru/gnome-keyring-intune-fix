# Troubleshooting Guide

## Quick Diagnostic

Run the diagnostic script to collect system information:

```bash
sudo bash scripts/diagnose.sh
```

For deeper analysis with Python D-Bus tracebacks:

```bash
sudo bash scripts/diagnose-local.sh
```

---

## Common Issues

### 1. Error `[4kv4v]` — "Something went wrong"

**Symptom:** Intune Company Portal shows `[4kv4v]` after successful Entra ID login.

**Diagnosis:**
```bash
# Check if login.keyring exists and is functional
ls -la ~/.local/share/keyrings/
cat ~/.local/share/keyrings/default
head -n 5 ~/.local/share/keyrings/login.keyring
```

**Fix:**
```bash
sudo bash scripts/fix-keyring.sh
```

Then **log out and log back in**, reopen Company Portal, and try enrollment again.

---

### 2. Error `[4u3gb]` — Token Storage Failure

**Symptom:** Enrollment starts but fails with `[4u3gb]`.

**Diagnosis:** Usually caused by corrupted Intune/broker cache from previous failed attempts.

**Fix:**
```bash
# Clean caches manually
rm -rf ~/.cache/intune-portal \
       ~/.config/intune-portal \
       ~/.config/microsoft-identity-broker \
       ~/.local/state/microsoft-identity-broker

# Then fix the keyring
sudo bash scripts/fix-keyring.sh
```

Consider using `insiders-fast` channel if the issue persists:
```
Types: deb
URIs: https://packages.microsoft.com/repos/microsoft-ubuntu-noble-prod/
Suites: noble insiders-fast
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/microsoft.gpg
```

---

### 3. Keyring is 90 bytes (minimal/broken)

**Symptom:** `login.keyring` exists but is only ~90 bytes.

**Cause:** The keyring was created by `gnome-keyring-daemon --login` without proper collection metadata. The Secret Service API doesn't recognize it.

**Fix:**
```bash
sudo bash scripts/fix-keyring.sh
```

The script will detect the undersized keyring, back it up, and create a proper plain-text INI keyring.

---

### 4. `org.freedesktop.secrets` Not Available on D-Bus

**Symptom:** `diagnose.sh` reports "org.freedesktop.secrets NÃO DISPONÍVEL".

**Diagnosis:**
```bash
# Check if gnome-keyring-daemon is running
pgrep -f gnome-keyring-daemon

# Check D-Bus bus
busctl --user list | grep secrets
```

**Common causes:**
- User is not logged into a graphical GNOME session
- `gnome-keyring` package is not installed
- Multiple zombie `gnome-keyring-daemon` processes blocking the bus

**Fix:**
```bash
# Kill zombie processes and restart
pkill -f gnome-keyring-daemon
# Log out and log back in
```

---

### 5. `Default_Keyring.keyring` Appears After Fix

**Symptom:** A `Default_Keyring.keyring` file appears in the keyrings directory after applying the fix.

**Cause:** Race condition — the `microsoft-identity-broker` started before the keyring unlock service, forcing GNOME to create a fallback keyring.

**Fix:** This is exactly what the systemd user service prevents. Verify it's enabled:
```bash
systemctl --user is-enabled unlock-keyring-intune.service
```

If not enabled:
```bash
sudo bash scripts/fix-keyring.sh
```

Then remove the fallback keyring:
```bash
rm -f ~/.local/share/keyrings/Default_Keyring.keyring
```

---

### 6. `user.keystore` Causing D-Bus Freezes

**Symptom:** The entire Secret Service API hangs/freezes. `secret-tool` commands block indefinitely.

**Cause:** An encrypted `user.keystore` file exists and the daemon cannot decrypt it (because `authd` doesn't pass the password).

**Fix:**
```bash
# Move the keystore to backup
mv ~/.local/share/keyrings/user.keystore ~/.local/share/keyrings/user.keystore.bak

# Kill the frozen daemon
pkill -f gnome-keyring-daemon

# Log out and log back in
```

---

### 7. Script Fails with "ERRO: Edite este script" (configure-entra-id.sh)

**Symptom:** `configure-entra-id.sh` exits with an error about placeholder values.

**Fix:** Edit the script and replace the placeholder values with your organization's Azure AD configuration:

```bash
YOUR_CLIENT_ID="your-app-registration-client-id"
YOUR_ISSUER_ID="your-azure-ad-tenant-id"
YOUR_DOMAIN_SUFFIX="@yourdomain.com"
```

These values come from your Azure Portal → App Registrations and Azure Active Directory → Properties.

---

## Diagnostic Checklist

| Check | Command | Expected |
|-------|---------|----------|
| GNOME Keyring installed | `dpkg -l gnome-keyring` | `ii` status |
| login.keyring exists | `ls -la ~/.local/share/keyrings/login.keyring` | File exists, >100 bytes |
| login.keyring is plain-text | `head -1 ~/.local/share/keyrings/login.keyring` | `[keyring]` |
| default alias set | `cat ~/.local/share/keyrings/default` | `login` |
| No user.keystore | `ls ~/.local/share/keyrings/user.keystore` | File not found |
| Daemon running | `pgrep -f gnome-keyring-daemon` | Single PID |
| D-Bus secrets available | `busctl --user list \| grep secrets` | `org.freedesktop.secrets` |
| Unlock service enabled | `systemctl --user is-enabled unlock-keyring-intune` | `enabled` |
| Intune cache clean | `ls ~/.cache/intune-portal` | Directory not found |

---

## Getting Help

If the issue persists after running all scripts:

1. Run `sudo bash scripts/diagnose.sh > diag.txt`
2. Run `sudo bash scripts/diagnose-local.sh > diag-local.txt`
3. Open an [issue](https://github.com/GMikeru/Gnome-Keyring-Intune-Linux-Fix-rkv4v/issues) with both files attached
