# CPU throttling on the Proxmox host

Lower the power draw and noise of a Proxmox host with an Intel CPU: power limit in the BIOS, then turbo, governor and energy performance preference (EPP) through the `cpu-powersave` command, reapplied at every boot.

|               |                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------------------------- |
| **Target**    | Proxmox VE 9 host (Debian 13), Intel CPU with the `intel_pstate` driver                                 |
| **Files**     | `/usr/local/sbin/cpu-powersave`, `/etc/cpu-powersave.conf`, `/etc/systemd/system/cpu-powersave.service` |
| **Tested on** | Intel Core Ultra 9 185H                                                                                 |

## Script

Set the BIOS first (step 0), then:

```bash
curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/pve/cpu-powersave.sh | bash
cpu-powersave                                                                         # change profile later
```

The script saves the BIOS PL1/PL2 limits: `--check` then reports a BIOS reset. It installs the Balanced profile only if no profile is saved yet, and reports TLP, `tuned` or `power-profiles-daemon` if they are running.

Check: `curl … | bash -s -- --check` · undo: `--uninstall`.

## Manual

### 0. BIOS

The only power setting; its name depends on the motherboard (*Power Mode*, *Power Limit*, *TDP*…).

| Limit           | Role                                   |
| --------------- | -------------------------------------- |
| PL1 (sustained) | maximum power under sustained load     |
| PL2 (bursts)    | maximum power during short bursts      |

> For a server, lowering PL2 mostly reduces peaks and fan noise. Example on a Core Ultra 9 185H: *Quiet* mode = PL1 45 W, PL2 50 W, versus 45 / 70 W in normal mode.

### 1. Inspect the hardware

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver                               # intel_pstate
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor                             # performance on Proxmox
cat /sys/class/powercap/intel-rapl:0/constraint_{0,1}_power_limit_uw                  # PL1, PL2 in µW
```

### 2. Install the `cpu-powersave` command

The command lives in the script, between `<<'TOOL'` and `TOOL`:

```bash
curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/pve/cpu-powersave.sh \
  | sed -n "/<<'TOOL'/,/^TOOL$/{//!p}" > /usr/local/sbin/cpu-powersave
chmod 755 /usr/local/sbin/cpu-powersave
printf 'TURBO=off\nEPP=balance_power\n' > /etc/cpu-powersave.conf                     # Balanced profile
```

### 3. Create the systemd service

```bash
cat > /etc/systemd/system/cpu-powersave.service <<'EOF'
[Unit]
Description=CPU powersave (turbo, governor, EPP)
After=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cpu-powersave apply

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cpu-powersave.service
systemctl restart cpu-powersave.service
```

> `restart`, not `enable --now`: an already active `oneshot` service does not run again.

### 4. Check

```bash
cpu-powersave status                                                                  # Saved = Applied
journalctl -u cpu-powersave -b --no-pager | grep failed                               # empty
```

## Change profile

```bash
cpu-powersave
```

The menu shows the current state, offers the profiles, asks for confirmation, then saves and applies right away, without a reboot.

| Profile      | `TURBO` | `EPP`                 | Use                                |
| ------------ | ------- | --------------------- | ---------------------------------- |
| Eco          | `off`   | `power`               | lowest consumption                 |
| **Balanced** | `off`   | `balance_power`       | recommended for a server           |
| Performance  | `on`    | `balance_performance` | responsive, PC default             |
| Max          | `on`    | `performance`         | max frequency at the slightest load |

## Undo

```bash
systemctl disable --now cpu-powersave.service
rm -f /etc/systemd/system/cpu-powersave.service /usr/local/sbin/cpu-powersave /etc/cpu-powersave.conf
systemctl daemon-reload
echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo
for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do echo balance_performance > "$f"; done
```

> The governor returns to the kernel default at next reboot.

## Notes

- **Levers**: the BIOS caps power under sustained load; turbo and EPP act on short bursts, most of a home server's load.
- **Governor**: the Proxmox kernel boots with `performance`, which locks EPP to `performance`; without switching to `powersave`, EPP would have no effect.
- **Conflicts**: do not combine with TLP, `tuned` or `power-profiles-daemon`: the last writer wins.
