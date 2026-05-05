# UPS Cluster Agent

A lightweight, dependency-free Bash agent that monitors UPS status across multiple servers and coordinates graceful shutdown using a quorum-based voting system.

Designed for **Proxmox VE** hosts but works on any Debian/Ubuntu server with NUT installed.

---

## How It Works

Each server runs a small agent that:

1. Reads UPS status every N seconds via NUT (`upsc`)
2. Shares its status with peers over a simple HTTP gossip API
3. Evaluates a quorum — how many nodes are on battery
4. If quorum is reached, starts a countdown to shutdown
5. Before shutdown, gracefully stops all VMs and LXC containers via `qm` / `pct`

```
Server 1 (APC UPS)          Server 2 (Powercom UPS)
┌─────────────────┐          ┌─────────────────┐
│  UPS monitor    │◄────────►│  UPS monitor    │
│  Gossip agent   │  :9213   │  Gossip agent   │
│  Decision engine│          │  Decision engine│
└────────┬────────┘          └────────┬────────┘
         │                            │
    qm/pct shutdown             qm/pct shutdown
```

### Shutdown triggers

| Condition | Action |
|---|---|
| Only this node on battery, others on mains | Wait — local power issue |
| Majority of nodes on battery (default policy) | Start countdown (5 min default) |
| Battery runtime < 9 min | **Immediate shutdown** — bypasses quorum |
| Battery charge < 20% | **Immediate shutdown** — bypasses quorum |
| All peers unreachable while on battery | **Autonomous shutdown** after timeout |
| Power restored during countdown | Countdown cancelled |

---

## Requirements

- Debian 11+ / Ubuntu 20.04+ (or Proxmox VE 7+)
- Bash 5+, `curl`, `netcat-traditional`
- NUT (Network UPS Tools) — installed automatically by the installer
- UPS connected via USB or RS-232

---

## Installation

Clone or download the repository, then run the installer on **each host**:

```bash
git clone https://github.com/yourname/ups-cluster-agent
cd ups-cluster-agent
sudo bash install.sh
```

The installer will guide you through 5 interactive steps:

```
BLOCK 1 — Server name and shutdown priority
BLOCK 2 — UPS detection, NUT configuration, USB permissions
BLOCK 3 — Cluster settings (gossip port, quorum policy, delay)
BLOCK 4 — Shutdown thresholds (runtime, battery %)
BLOCK 5 — Cluster peers (hostname + IP → written to /etc/hosts)
```

After completing all steps, the agent starts automatically.

---

## File Layout

```
/opt/ups-agent/
  ups_agent.sh          ← main agent process

/etc/ups-agent/
  cluster.conf          ← agent configuration
  pre-shutdown.sh       ← stops VMs/LXC before poweroff

/etc/systemd/system/
  ups-agent.service     ← systemd unit

/var/log/
  ups-agent.log         ← event log
```

---

## Configuration

`/etc/ups-agent/cluster.conf`:

```bash
# This server
HOST_NAME="pve01"
HOST_IP=""                   # empty = auto-detected at startup
SHUTDOWN_PRIORITY=1          # 1 = shuts down first

# UPS (NUT)
UPS_NAME="ups"               # must match name in /etc/nut/ups.conf
POLL_INTERVAL=30             # seconds between UPS polls
CRITICAL_RUNTIME_MIN=9       # immediate shutdown if runtime < N minutes
CRITICAL_BATTERY=20          # immediate shutdown if charge < N%

# Cluster
GOSSIP_PORT=9213
PEERS="pve02:9213,pve03:9213"   # hostnames resolved via /etc/hosts
QUORUM_POLICY="majority"        # majority | all | any
SHUTDOWN_DELAY=300              # seconds to wait after quorum before shutdown
```

### Quorum policies

| Policy | Shutdown triggers when... | Best for |
|---|---|---|
| `majority` | More than 50% of nodes on battery | Most setups |
| `all` | Every node is on battery | Nodes on separate power feeds |
| `any` | At least one node on battery | Maximum data protection |

### Shutdown priority

Nodes shut down in order of `SHUTDOWN_PRIORITY` (lowest first). Set your database server to the highest number so it shuts down last, giving other services time to disconnect cleanly.

---

## Pre-shutdown Script

`/etc/ups-agent/pre-shutdown.sh` runs before `shutdown -h now`. On Proxmox hosts it:

1. Sends ACPI shutdown to all running VMs (`qm shutdown`)
2. Sends shutdown to all running LXC containers (`pct shutdown`)
3. Waits up to 60 seconds for graceful stop
4. Force-stops anything that didn't stop in time
5. Runs `sync` to flush disk buffers

You can configure per-VM actions (shutdown vs hibernate) by editing the `VM_ACTIONS` array at the top of the script:

```bash
declare -A VM_ACTIONS
VM_ACTIONS[100]="hibernate"   # suspend to disk instead of shutdown
VM_ACTIONS[101]="shutdown"    # explicit shutdown (default)
```

---

## Dynamic IP Support

Peers are referenced by **hostname**, not IP address. The installer writes entries to `/etc/hosts`:

```
10.0.0.12  pve02  # ups-agent
10.0.0.13  pve03  # ups-agent
```

If a peer's IP changes, update `/etc/hosts` — no agent restart or config changes needed:

```bash
sed -i 's/10.0.0.12 pve02/10.0.0.15 pve02/' /etc/hosts
```

---

## Useful Commands

```bash
# Service status
systemctl status ups-agent

# Live log
tail -f /var/log/ups-agent.log

# UPS status (NUT)
upsc ups@localhost

# Gossip API — this node
curl http://localhost:9213/status | python3 -m json.tool

# Gossip API — check all nodes
for host in pve01 pve02; do
  echo "=== $host ==="
  curl -s http://$host:9213/status | python3 -m json.tool
done

# Test pre-shutdown script (safe — does NOT power off)
sudo bash /etc/ups-agent/pre-shutdown.sh

# Restart after config change
systemctl restart ups-agent
```

---

## Gossip API Response

`GET http://<host>:9213/status`

```json
{
  "host": "pve01",
  "ip": "10.0.0.11",
  "role": "proxmox",
  "priority": 1,
  "on_battery": false,
  "battery_pct": 100,
  "runtime_min": 17,
  "timestamp": "2026-04-28T10:00:00Z"
}
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `UPS not responding` | NUT not running or wrong UPS name | `systemctl status nut-server` · `upsc ups@localhost` |
| `insufficient permissions` on USB | udev rules not applied | Check `/etc/udev/rules.d/99-nut-ups.rules` · re-run installer |
| Peer shows `unreachable` | Firewall blocking port 9213 | Allow port 9213 from peer IPs |
| Agent not starting | Config error | `journalctl -u ups-agent -n 30` |
| Shutdown not triggered | Quorum not reached | Check `QUORUM_POLICY` · verify peer statuses via gossip API |
| Pre-shutdown too slow | VMs take long to stop | Increase `SHUTDOWN_TIMEOUT` in `pre-shutdown.sh` · raise `CRITICAL_RUNTIME_MIN` |

---

## Scaling

The agent scales to any number of nodes — add more entries to `PEERS` and re-run on the new host. The `majority` quorum policy automatically adjusts: 2-of-3, 3-of-5, etc.

For large clusters (10+ nodes), replace `netcat` gossip with `socat` for parallel connection handling.

---

## License

MIT
