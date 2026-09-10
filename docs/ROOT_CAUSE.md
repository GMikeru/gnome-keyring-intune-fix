# Root Cause Analysis: Intune Enrollment Failure `[4kv4v]` on Ubuntu + Entra ID

## Overview

Microsoft Intune on Linux requires a **GNOME Keyring of type `login`** (file `login.keyring`) **without a password** to store MSAL authentication tokens via the `org.freedesktop.secrets` D-Bus API (Secret Service).

When using **Entra ID (Azure AD) authentication via `authd`** on Ubuntu 24.04+, the keyring is never created or unlocked automatically, causing Intune enrollment to fail with error code `[4kv4v]`.

**Affected environments:** Ubuntu 22.04+ | Entra ID via authd | LUKS | GNOME Desktop (GDM)

---

## The Error Chain

### Step-by-step failure sequence

1. User opens **Company Portal** (Intune Portal) and successfully authenticates via Entra ID
2. The `microsoft-identity-broker` attempts to persist MSAL tokens via `org.freedesktop.secrets`
3. Token storage fails because the `login.keyring` is **locked, missing, or encrypted with a password the system cannot provide**
4. Error appears: **"Something went wrong. [4kv4v]"** or **"Couldn't enroll your device. Creating a new item in the default secret collection."**

### Why `authd` breaks the keyring flow

The `authd` broker performs **OAuth/OIDC authentication directly against Azure AD**. The user's password is **never passed to the local PAM stack**. System logs confirm:

```
gkr-pam: no password is available for user
gkr-pam: couldn't unlock the login keyring.
```

The PAM module `pam_gnome_keyring.so` is present in `gdm-authd`, but since `authd` authenticates externally, `pam_set_item(PAM_AUTHTOK)` is never called — the password never reaches the local keyring subsystem.

---

## The Discovery: Plain-Text INI Keyrings

### How GNOME Keyring stores unencrypted files

A deep analysis of `login.keyring` files created manually (via Seahorse with an empty password) revealed that GNOME Keyring, when configured with a blank password, **does not encrypt the file on disk**. Instead, it stores the keyring as **plain-text in INI format**:

```ini
[keyring]
display-name=login
ctime=1789066652
mtime=0
lock-on-idle=false
lock-after=false
```

When Intune/MSAL stores tokens, the daemon simply appends new plain-text sections like `[5]`, `[5:attribute0]`, etc. with the corresponding data.

**This means we can create a fully functional keyring by writing a text file directly** — no GUI prompts, no D-Bus interactions, no user intervention. This is the foundation of our automated fix.

---

## Approaches Tested

| Approach | Result | Reason |
|----------|--------|--------|
| `secretstorage.create_collection()` via root/SSH | ❌ `PromptDismissedException` | GUI prompt never appears in remote session |
| `gnome-keyring-daemon --login` + `--unlock` via root | ⚠️ Creates 90-byte file | Minimal keyring, Intune doesn't recognize as collection |
| `echo -n ""` on stdin | ❌ Daemon ignores | Needs NUL byte terminator (`printf '\0'`) |
| `pgrep -x gnome-keyring-daemon` | ❌ Process not found | Kernel truncates name to 15 chars, use `pgrep -f` |
| PAM `pam_gnome_keyring.so` with authd | ❌ Doesn't work | authd doesn't call `pam_set_item(PAM_AUTHTOK)` |
| Seahorse manual (empty password) | ✅ Works | Creates collection via D-Bus in user session |
| Autostart + secretstorage in user session | ✅ Previous solution | Prompt appears on screen, user leaves empty (obsolete) |
| **Write `login.keyring` (INI format) directly** | ✅ **Definitive** | 100% automated, no GUI prompts, no interaction |

---

## Advanced Engineering Details

### 1. The `user.keystore` Master Lockup

The `user.keystore` file is the master encrypted key repository for GNOME Keyring. If it exists and is encrypted with the machine's old password, the daemon attempts to load it at boot. Since `authd` doesn't pass the password to PAM, this master decryption fails, which **freezes the entire `org.freedesktop.secrets` D-Bus API**.

Moving `user.keystore` to a backup (`user.keystore.bak_...`) is mandatory to unblock the secrets API. Applications like Google Chrome will continue reading their keys from the unencrypted `login.keyring` without depending on the master keystore.

### 2. Daemon Caching and Process Conflicts

- **Disk Caching:** The GNOME Keyring daemon reads `~/.local/share/keyrings` only once (at login). Modifying files on disk while the session is open means the in-memory daemon continues using the old representation, triggering D-Bus errors like `UnknownMethod`.
- **PID Conflicts:** Sequential unlock command executions outside the graphical session spawn accumulated zombie processes (sometimes up to 6 concurrent processes!).
- **The Fix:** Running `pkill -u <UID> -f gnome-keyring-daemon` immediately after writing files forces termination of all zombie processes, allowing the next D-Bus call to initialize a single, clean process fully updated from disk.

### 3. Boot Race Condition: Early Unlock via Systemd User Service

- **The Problem:** At user login, background services like `microsoft-identity-broker` or Google Chrome initialize very quickly and request keys from Secret Service before GNOME loads its GUI. Since traditional GNOME autostart (`.desktop`) runs late, the `login.keyring` was still locked during early boot. This forced the GNOME Keyring daemon to create a fallback keyring called `Default_Keyring.keyring` and register it as the default master in memory, leaving the real Intune keyring completely locked.
- **The Fix:** Create a global systemd user service (`/etc/systemd/user/unlock-keyring-intune.service`) that executes in the early boot phase (`WantedBy=default.target` and `After=gnome-keyring-daemon.service`). This service sends the unlock signal with an empty password the millisecond the system opens the user session.

### 4. `/etc/profile.d/` Script Conflicts

- **The Problem:** Running unlock commands in legacy `/etc/profile.d/` scripts causes keyring file corruption and GDM conflicts. The `/etc/profile.d/` directory executes on every shell opening (including SSH, sudo, silent logins, etc.), often at times when the D-Bus session or the main keyring daemon aren't fully initialized, forcing the daemon to generate invalid 90-byte keyring files.
- **The Fix:** The correction script detects and removes any `/etc/profile.d/unlock-keyring.sh` files.

### 5. Why `printf '\0'` and not `echo -n ""`?

The `gnome-keyring-daemon` expects the password terminated with a NUL byte (`\0`). `echo -n ""` sends 0 bytes — the daemon ignores it. `printf '\0'` sends 1 byte (NUL) = empty password correctly terminated.

### 6. Why `pgrep -f` and not `pgrep -x`?

The Linux kernel truncates process names to 15 characters in `/proc/PID/comm`. `gnome-keyring-daemon` (20 chars) becomes `gnome-keyring-d` (15 chars). `pgrep -x` does exact match on `comm`, so it never finds it. `pgrep -f` matches against the full cmdline.

---

## Deployment Flow

```
     SSH as root → Run fix-keyring.sh or install-intune.sh
                                  ↓
     Write login.keyring plain-text directly for all users
                                  ↓
      Create default alias and clean corrupted Intune caches
                                  ↓
    Install global systemd user service + autostart for early unlock
                                  ↓
                       User logs into GNOME
                                  ↓
     Systemd unlocks login.keyring silently on boot
                                  ↓
           Intune/MSAL stores tokens and works first try
```

---

## Messages That Are NOT Errors

| Message | Explanation |
|---------|-------------|
| `microsoft-identity-broker.service could not be found` | **Normal** in broker v3.x — uses D-Bus activation, not systemd |
| Starting broker manually via `/opt/microsoft/identity-broker/bin/...` | **Don't do this** — without proper D-Bus context, it resolves nothing |

---

## References

- [hiaror/intune-linux-4kv4v-keyring-fix](https://github.com/hiaror/intune-linux-4kv4v-keyring-fix) — Root cause and validated lab fixes
- [Gist undone37](https://gist.github.com/undone37/b5a37a4da7b58e8f1806d38839ee8d8f) — Fix for KDE/Kubuntu (`org.freedesktop.impl.portal.Secret`)
- [shell-intune-samples #261](https://github.com/microsoft/shell-intune-samples/issues/261) — Kubuntu 26.04 + `[4kv4v]`
- [Tech Community #4360127](https://techcommunity.microsoft.com/discussions/microsoft-intune/ubuntu-24-04-lts--entra-id-authentication--intune-enrollment/4360127) — Ubuntu 24.04 + Entra ID + Intune
- [GNOME Keyring — ArchWiki](https://wiki.archlinux.org/title/GNOME/Keyring)
- [Secret Service API — Freedesktop](https://specifications.freedesktop.org/secret-service-spec/latest/)
- [Microsoft Intune Linux Enrollment](https://learn.microsoft.com/en-us/intune/intune-service/user-help/enroll-device-linux)
