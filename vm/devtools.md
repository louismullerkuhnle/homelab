# Development tools

What you need to code on a dev VM, or to let Claude Code work on it: [mise](https://mise.jdx.dev) for node, bun, python, uv…, GitHub CLI and Claude Code.

|                  |                                                                                                         |
| ---------------- | ------------------------------------------------------------------------------------------------------- |
| **Target**       | Ubuntu Server 26.04 LTS dev VM                                                                          |
| **Requirements** | [init.md](init.md), and [docker.md](docker.md) if projects use Docker                                   |
| **Files**        | `/etc/apt/keyrings/{mise.asc,githubcli.gpg}`, `/etc/apt/sources.list.d/{mise,github-cli}.sources`, `~/.config/mise/config.toml`, `~/.bashrc`, `~/.local/bin/claude` |

## Why a separate dev VM

An agent like Claude Code runs commands. On a dedicated VM, it can reach neither production services nor production secrets, and a mistake is fixed by restoring a snapshot. Mount the NAS read-only (`ro`), or not at all.

## Script

```bash
curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/vm/devtools.sh | sudo bash
```

On first run, the script asks for the list of tools (default: `node@lts bun@latest python@latest uv@latest`) and whether to install Claude Code. Log in again afterwards to enable mise, then run `claude` to authenticate.

> Change the tools: run again with `--reconfigure`. Check: `--check`.

## Manual

### 1. Build tools and utilities

```bash
sudo apt install -y build-essential pkg-config jq ripgrep fd-find unzip
```

### 2. mise and GitHub CLI repositories

```bash
sudo curl -fsSL https://mise.jdx.dev/gpg-key.pub -o /etc/apt/keyrings/mise.asc
sudo curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg
gpg --show-keys /etc/apt/keyrings/mise.asc /etc/apt/keyrings/githubcli.gpg
```

> Expected fingerprints: mise `24853EC9F655CE80B48E6C3A8B81C9D17413A06D`; GitHub CLI `2C6106201985B60E6C7AC87323F3D4EA75716059` and `7F38BBB59D064DBCB3D84D725612B36462313325`.

```bash
sudo tee /etc/apt/sources.list.d/mise.sources >/dev/null <<EOF
Types: deb
URIs: https://mise.jdx.dev/deb
Suites: stable
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/mise.asc
EOF

sudo tee /etc/apt/sources.list.d/github-cli.sources >/dev/null <<EOF
Types: deb
URIs: https://cli.github.com/packages
Suites: stable
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/githubcli.gpg
EOF

sudo apt update && sudo apt install -y mise gh
```

### 3. Languages, as the user

```bash
mise use --global node@lts bun@latest python@latest uv@latest
echo 'eval "$(mise activate bash)"' >> ~/.bashrc
```

> Installed in `~/.local/share/mise`, nothing system-wide. Each project can pin its versions in a `mise.toml`.

### 4. Claude Code, as the user

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

> Official installer: installs into `~/.local/bin` and updates itself. It refuses to run with `sudo`.

## Undo

Restore the snapshot taken before.

## Notes

- **Per-project versions**: `mise use node@22` in the project folder creates a `mise.toml` to commit with the code.
- **GitHub**: `gh auth login`, with a token limited to the dev repositories.
- **Updates**: mise and gh follow `apt full-upgrade`; languages, `mise upgrade`.
