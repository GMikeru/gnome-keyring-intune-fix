---
name: Bug Report
about: Report an issue with keyring fix, Intune enrollment, or scripts
title: "[BUG] "
labels: bug
assignees: ''
---

## Environment

- **Ubuntu version:** (e.g., 24.04 LTS)
- **Desktop environment:** (e.g., GNOME 46)
- **Authentication method:** (e.g., Entra ID via authd)
- **Intune portal version:** (`dpkg -l intune-portal | grep ii`)
- **Disk encryption:** (LUKS / None)

## Describe the Bug

A clear description of what happened.

## Error Message

```
Paste the exact error message here (e.g., [4kv4v], [4u3gb], etc.)
```

## Steps to Reproduce

1. ...
2. ...
3. ...

## Script Output

Please attach the output of:

```bash
sudo bash scripts/diagnose.sh > diag.txt 2>&1
```

<details>
<summary>Diagnostic output</summary>

```
Paste output here
```

</details>

## Additional Context

Any additional context, screenshots, or log entries.
