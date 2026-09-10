# 🔐 GNOME Keyring Fix for Microsoft Intune on Linux

> **Automated fix for Intune enrollment failures (`[4kv4v]`, `[4u3gb]`) on Ubuntu Linux with Microsoft Entra ID (Azure AD) authentication.**

[![Ubuntu 22.04+](https://img.shields.io/badge/Ubuntu-22.04%20|%2024.04%20|%2026.04-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)](scripts/)
[![Maintenance](https://img.shields.io/badge/Maintained-Yes-green.svg)](https://github.com/GMikeru/Gnome-Keyring-Intune-Linux-Fix-rkv4v/commits/main)

---

## 📋 The Problem

When enrolling Ubuntu Linux devices into **Microsoft Intune** using **Entra ID (Azure AD)** authentication via `authd`, users encounter:

```
❌ "Something went wrong. [4kv4v]"
❌ "Couldn't enroll your device. Creating a new item in the default secret collection."
```

**Root Cause:** The `authd` broker performs OAuth/OIDC authentication directly against Azure AD — the user's password **never reaches the local PAM stack**. This means `pam_gnome_keyring.so` cannot create or unlock the GNOME Keyring automatically. Without an unlocked keyring, the `microsoft-identity-broker` cannot store MSAL tokens via the `org.freedesktop.secrets` D-Bus API, causing enrollment to fail.

```
gkr-pam: no password is available for user
gkr-pam: couldn't unlock the login keyring.
```

---

## 💡 The Solution

This project provides a **fully automated, headless, 100% remote-deployable** fix:

```
SSH as root → Run fix script
         ↓
Write login.keyring as plain-text INI (no GUI prompts needed!)
         ↓
Create 'default' alias + clean corrupted Intune/broker caches
         ↓
Install early systemd user service + XDG autostart for unlock
         ↓
User logs into GNOME → Keyring unlocked silently on boot
         ↓
Intune/MSAL stores tokens successfully → Enrollment works!
```

### 🔬 Key Discovery

**GNOME Keyring files with no password are stored as plain-text INI files on disk** — not encrypted binary. This means we can create a fully functional keyring by simply writing a text file:

```ini
[keyring]
display-name=login
ctime=1789066652
mtime=0
lock-on-idle=false
lock-after=false
```

This eliminates the need for any GUI prompts, D-Bus interactions, or user intervention during deployment.

---

## 🚀 Quick Start

### Option 1: Fix keyring only (existing Intune installation)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/GMikeru/Gnome-Keyring-Intune-Linux-Fix-rkv4v/main/scripts/fix-keyring.sh)"
```

### Option 2: Clone and run

```bash
git clone https://github.com/GMikeru/Gnome-Keyring-Intune-Linux-Fix-rkv4v.git
cd Gnome-Keyring-Intune-Linux-Fix-rkv4v

# Fix keyring for all users
sudo bash scripts/fix-keyring.sh

# Or: Full Intune installation + keyring fix
sudo bash scripts/install-intune.sh
```

### Option 3: User-level fix (no root required)

```bash
bash scripts/create-keyring.sh
```

---

## 📂 Scripts

| Script | Privilege | Purpose |
|--------|-----------|---------|
| [`fix-keyring.sh`](scripts/fix-keyring.sh) | `sudo` | **Primary fix** — Creates/repairs login.keyring, removes stale keyrings, installs unlock service |
| [`install-intune.sh`](scripts/install-intune.sh) | `sudo` | Full Intune + Edge installation with GPG keys, repos, polkit, systemd, and keyring fix |
| [`configure-entra-id.sh`](scripts/configure-entra-id.sh) | `sudo` | Installs and configures `authd` + `authd-msentraid` broker for Entra ID |
| [`create-keyring.sh`](scripts/create-keyring.sh) | user | Standalone keyring initializer — runs as the logged-in user, no root needed |
| [`diagnose.sh`](scripts/diagnose.sh) | `sudo` | Read-only system diagnostic — packages, services, PAM, keyrings, D-Bus, logs |
| [`diagnose-local.sh`](scripts/diagnose-local.sh) | `sudo` | Deep local diagnostic with Python D-Bus/SecretStorage traceback analysis |
| [`test-keyring.sh`](scripts/test-keyring.sh) | user | Non-destructive user-level test runner for keyring correction validation |

---

## 🔧 What `fix-keyring.sh` Does

1. **Writes a plain-text INI `login.keyring`** for every user in `/home/*` (backs up encrypted keyrings)
2. **Moves `user.keystore`** to backup (prevents Secret Service lockup from encrypted master keystore)
3. **Maps the `default` alias** to `login` (required for Secret Service API resolution)
4. **Kills zombie `gnome-keyring-daemon` processes** (forces reload from disk)
5. **Cleans corrupted Intune/broker caches** (`~/.cache/intune-portal`, `~/.config/microsoft-identity-broker`, etc.)
6. **Installs systemd user service** for early keyring unlock (prevents race conditions with `microsoft-identity-broker`)
7. **Installs XDG autostart** as fallback unlock mechanism
8. **Removes legacy `/etc/profile.d/unlock-keyring.sh`** scripts that cause keyring file corruption
9. **Validates** the fix via Python `secretstorage` D-Bus checks (non-blocking)

All operations are **idempotent** — safe to run multiple times.

---

## 📖 Documentation

- [**Root Cause Analysis**](docs/ROOT_CAUSE.md) — Deep technical analysis of the `[4kv4v]` error chain, PAM/authd interaction, and the plain-text INI discovery
- [**Troubleshooting Guide**](docs/TROUBLESHOOTING.md) — Common issues, diagnostic steps, and solutions

---

## 🖥️ Tested Environments

| Component | Versions |
|-----------|----------|
| **Ubuntu** | 22.04 LTS, 24.04 LTS, 26.04 LTS |
| **Desktop** | GNOME (GDM) |
| **Auth** | Microsoft Entra ID via `authd` + `authd-msentraid` |
| **Disk** | LUKS full-disk encryption |
| **Intune** | `intune-portal` (stable channel) |
| **Broker** | `microsoft-identity-broker` v3.x (D-Bus activated) |

---

## 🤝 Contributing

Contributions are welcome! If you've encountered this issue in a different environment (KDE, Fedora, etc.), please open an issue with:

1. Output of `sudo bash scripts/diagnose.sh`
2. Your Ubuntu/distro version and desktop environment
3. Authentication method (Entra ID, local, LDAP, etc.)

See the [issue template](.github/ISSUE_TEMPLATE/bug_report.md) for guidance.

---

## 📚 References

- [hiaror/intune-linux-4kv4v-keyring-fix](https://github.com/hiaror/intune-linux-4kv4v-keyring-fix) — Root cause analysis and validated lab fixes
- [Gist undone37](https://gist.github.com/undone37/b5a37a4da7b58e8f1806d38839ee8d8f) — Fix for KDE/Kubuntu (`org.freedesktop.impl.portal.Secret`)
- [shell-intune-samples #261](https://github.com/microsoft/shell-intune-samples/issues/261) — Kubuntu 26.04 + `[4kv4v]` issue
- [Tech Community #4360127](https://techcommunity.microsoft.com/discussions/microsoft-intune/ubuntu-24-04-lts--entra-id-authentication--intune-enrollment/4360127) — Ubuntu 24.04 + Entra ID + Intune discussion
- [GNOME Keyring — ArchWiki](https://wiki.archlinux.org/title/GNOME/Keyring)
- [Secret Service API — Freedesktop](https://specifications.freedesktop.org/secret-service-spec/latest/)
- [Microsoft Intune Linux Enrollment](https://learn.microsoft.com/en-us/intune/intune-service/user-help/enroll-device-linux)

---

## 📝 License

This project is licensed under the [MIT License](LICENSE).

---

## 👤 Author

**Gustavo Michel** ([@GMikeru](https://github.com/GMikeru))

IT Infrastructure & Endpoint Management Engineer specializing in cross-platform MDM deployments (Windows, macOS, Linux) with Microsoft Intune, Entra ID, and Ubuntu Pro/Landscape.