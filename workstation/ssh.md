# Workstation SSH key and config

One SSH key per workstation, short aliases for each machine, and the key added to the Proxmox host and the VMs. Required by [vm/init.md](../vm/init.md), which disables SSH passwords.

|            |                                                               |
| ---------- | ------------------------------------------------------------- |
| **Target** | Workstation: Linux, macOS or Windows 10/11                    |
| **Files**  | `~/.ssh/id_ed25519`, `~/.ssh/id_ed25519.pub`, `~/.ssh/config` |

## 1. Create the key

Once per workstation; skip if `~/.ssh/id_ed25519` already exists.

```bash
ssh-keygen -t ed25519 -C "<workstation name>"
```

> Set a passphrase: a stolen key alone is no longer enough. The SSH agent saves you from typing it again (step 2).

## 2. Load the key into the agent

| Workstation | Command                                                                                                   |
| ----------- | --------------------------------------------------------------------------------------------------------- |
| Linux       | `ssh-add ~/.ssh/id_ed25519`                                                                               |
| macOS       | `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`                                                          |
| Windows     | admin PowerShell: `Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent`, then `ssh-add` |

## 3. Declare the machines

`~/.ssh/config` (Windows: `%USERPROFILE%\.ssh\config`):

```
Host pve
  HostName <PVE_IP>
  User root

Host vm-prod
  HostName <VM_PROD_IP>
  User <user>

Host vm-dev
  HostName <VM_DEV_IP>
  User <user>

Host *
  IdentityFile ~/.ssh/id_ed25519
  ServerAliveInterval 30
```

## 4. Add the key to each machine

The password is asked one last time.

| Workstation   | Command                                                                                                                                                                   |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linux / macOS | `ssh-copy-id vm-prod`                                                                                                                                                     |
| Windows       | `type $env:USERPROFILE\.ssh\id_ed25519.pub \| ssh vm-prod "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"` |

> Alternative for the VMs: publish the public key on GitHub (**Settings** → **SSH and GPG keys**) and give your GitHub account when [vm/init](../vm/init.md) asks for it: the key is added automatically.

## 5. Check

```bash
ssh vm-prod                                                                           # logged in without a password
```

> Being asked for the key's **passphrase** is normal if the agent is not loaded; being asked for the account's **password** means the key is not installed.

## Notes

- **One key per workstation**, never copied between workstations: a lost workstation is revoked by deleting its line (comment `<workstation name>`) from `~/.ssh/authorized_keys` on each machine.
