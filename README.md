# Homelab

Homelab (Proxmox) : guides and scripts for installation, configuration and maintenance.

Each procedure has a step-by-step guide (`.md`) and a script (`.sh`) that does the same. Scripts run straight from GitHub, are safe to run again, and can be checked with `--check`.

## Procedures

| Machine      | Guide                                       | Role                                                  |
| ------------ | ------------------------------------------- | ----------------------------------------------------- |
| Workstation  | [workstation/ssh](workstation/ssh.md)       | SSH key, machine aliases, key added to the machines   |
| Proxmox host | [pve/cloudflared](pve/cloudflared.md)       | Web UI through a Cloudflare tunnel, behind Access     |
| Proxmox host | [pve/cpu-powersave](pve/cpu-powersave.md)   | Intel CPU throttling: turbo, governor, EPP            |
| VM           | [vm/init](vm/init.md)                       | First boot: system, hardened SSH, disk, NAS           |
| VM           | [vm/docker](vm/docker.md)                   | Docker Engine, log rotation                           |
| Dev VM       | [vm/devtools](vm/devtools.md)               | mise (node, bun, python…), GitHub CLI, Claude Code    |

On a VM: `init`, then `docker`, then `devtools` for a dev VM. The Proxmox procedures are independent.

## Running a script

Only requirement: `curl`. Present on Proxmox and standard Ubuntu; on Ubuntu *minimized*: `sudo apt update && sudo apt install -y curl`.

```bash
curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/vm/init.sh | sudo bash
```

| Option          | Effect                                                 |
| --------------- | ------------------------------------------------------ |
| `--check`       | checks without changing anything; exit code 0 or 1     |
| `--reconfigure` | asks the questions again                               |
| `--uninstall`   | undoes the procedure, when supported (see the guide)   |

Pass an option like this: `curl … | sudo bash -s -- --check`. On the Proxmox host you are root: no `sudo`.

**Settings**: on first run, each script asks its questions (user, NAS share…) with a default value, then saves the answers in `/etc/homelab.conf`. An environment variable takes precedence: `curl … | sudo env HL_IPV6=off bash`. Passwords and tokens are typed as hidden input and never leave the machine.

## Output

One line per action; the full command output goes to `/var/log/homelab/`.

```
[2/10] System updates
  ✓ Package index
  ✓ Upgrading 23 package(s)
  ! qemu-guest-agent does not start: journalctl -u qemu-guest-agent
```

`✓` done or compliant · `–` not applicable · `!` warning, the script goes on · `✗` failure, stops with the end of the command output.

## Prod and dev

Two separate VMs: prod runs the services (`init`, `docker`); dev is for coding and for agents like Claude Code (`init`, `docker`, `devtools`), with no production secrets and the NAS read-only. A mistake on dev is fixed by restoring a snapshot.

## Contributing

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/): `type(scope): description`, imperative mood. Types: `feat`, `fix`, `docs`, `refactor`, `ci`, `chore`. Scopes: `repo`, `workstation`, `pve`, `vm`.

CI runs `shellcheck` on every script and checks the guides' links on every push.
