#!/bin/bash
# =============================================================
# UPS Cluster Agent — Full Automatic Installation
# Includes NUT setup, agent configuration and cluster setup
# Usage: bash install.sh
# =============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; exit 1; }
info() { echo -e "${BLUE}[..]${NC}  $*"; }
ask()  { echo -e "${YELLOW}[?]${NC}   $*"; }
hr()   { echo "────────────────────────────────────────────"; }

[[ $EUID -ne 0 ]] && err "Please run as root: sudo bash install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   UPS Cluster Agent — Full Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─────────────────────── Check required files ────────────────────

for f in ups_agent.sh pre-shutdown.sh ups-agent.service; do
    [[ ! -f "$SCRIPT_DIR/$f" ]] && err "Missing file: $SCRIPT_DIR/$f"
done
ok "All agent files found"

# ══════════════════════════════════════════════
# BLOCK 1 — SERVER SETTINGS
# ══════════════════════════════════════════════

echo ""
hr
echo " BLOCK 1 — This Server"
hr

DEFAULT_NAME=$(hostname -s)
ask "Server name [$DEFAULT_NAME]:"
read -r INPUT_NAME
HOST_NAME="${INPUT_NAME:-$DEFAULT_NAME}"

ask "Shutdown priority (1=first, 2=second, ...) [1]:"
read -r INPUT_PRIO
SHUTDOWN_PRIORITY="${INPUT_PRIO:-1}"

# ══════════════════════════════════════════════
# BLOCK 2 — NUT SETUP
# ══════════════════════════════════════════════

echo ""
hr
echo " BLOCK 2 — NUT (UPS) Setup"
hr

info "Installing NUT packages..."
apt-get update -qq
apt-get install -y -qq nut nut-client usbutils
ok "NUT installed"

echo ""
info "USB devices found in system:"
USB_LIST=$(lsusb 2>/dev/null || echo "")
echo "$USB_LIST"
echo ""

ask "How is the UPS connected? [1] USB  [2] COM port (RS-232) [1]:"
read -r UPS_CONN
UPS_CONN="${UPS_CONN:-1}"

if [[ "$UPS_CONN" == "2" ]]; then
    UPS_DRIVER="apcsmart"
    ask "COM port device path [/dev/ttyS0]:"
    read -r UPS_PORT_INPUT
    UPS_PORT="${UPS_PORT_INPUT:-/dev/ttyS0}"
else
    UPS_DRIVER="usbhid-ups"
    UPS_PORT="auto"

    if echo "$USB_LIST" | grep -qi "american power\|051d"; then
        info "Detected APC UPS → driver: usbhid-ups"
    elif echo "$USB_LIST" | grep -qi "powercom\|0d9f"; then
        info "Detected Powercom UPS → driver: usbhid-ups"
    elif echo "$USB_LIST" | grep -qi "eaton\|cyber\|mustek"; then
        info "Detected compatible UPS → driver: usbhid-ups"
    else
        warn "UPS vendor not detected automatically"
        ask "NUT driver to use [usbhid-ups]:"
        read -r DRV_INPUT
        UPS_DRIVER="${DRV_INPUT:-usbhid-ups}"
    fi
fi

ask "UPS name in NUT (alphanumeric, no spaces) [ups]:"
read -r INPUT_UPS
UPS_NAME="${INPUT_UPS:-ups}"

ask "UPS description (free text) [Main UPS]:"
read -r UPS_DESC
UPS_DESC="${UPS_DESC:-Main UPS}"

# USB permissions
if [[ "$UPS_CONN" != "2" ]]; then
    info "Setting up USB permissions..."

    USB_IDS=""
    while IFS= read -r line; do
        ID=$(echo "$line" | grep -oP 'ID \K[0-9a-f]{4}:[0-9a-f]{4}')
        NAME=$(echo "$line" | sed 's/.*ID [0-9a-f:]*  //')
        echo "$NAME" | grep -qiE "hub|intel|megatrend|virtual|root" && continue
        [[ -n "$ID" ]] && USB_IDS="$USB_IDS $ID"
    done <<< "$USB_LIST"

    if [[ -n "$USB_IDS" ]]; then
        UDEV_RULES=""
        for ID in $USB_IDS; do
            VENDOR="${ID%%:*}"
            PRODUCT="${ID##*:}"
            UDEV_RULES="${UDEV_RULES}SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"${VENDOR}\", ATTRS{idProduct}==\"${PRODUCT}\", MODE=\"0664\", GROUP=\"nut\"\n"
        done

        printf "$UDEV_RULES" > /etc/udev/rules.d/99-nut-ups.rules
        ok "udev rules created: /etc/udev/rules.d/99-nut-ups.rules"

        if systemctl is-active --quiet systemd-udevd 2>/dev/null; then
            udevadm control --reload-rules && udevadm trigger
            ok "udev rules applied"
        else
            info "udevd not active (LXC/container?) — applying permissions directly..."
            while IFS= read -r usbline; do
                BUS=$(echo "$usbline" | grep -oP 'Bus \K\d+')
                DEV=$(echo "$usbline" | grep -oP 'Device \K\d+')
                ID=$(echo "$usbline"  | grep -oP 'ID \K[0-9a-f]{4}:[0-9a-f]{4}')
                echo "$ID" | grep -qiE "^1d6b|8087|046b" && continue
                [[ -z "$BUS" || -z "$DEV" ]] && continue
                DEV_PATH="/dev/bus/usb/$(printf '%03d' $BUS)/$(printf '%03d' $DEV)"
                if [[ -e "$DEV_PATH" ]]; then
                    chown root:nut "$DEV_PATH"
                    chmod 664 "$DEV_PATH"
                    ok "  Permissions set: $DEV_PATH"
                fi
            done <<< "$USB_LIST"
        fi
    fi
fi

# Write NUT config files
info "Writing /etc/nut/nut.conf..."
cat > /etc/nut/nut.conf << EOF
MODE=standalone
EOF

info "Writing /etc/nut/ups.conf..."
cat > /etc/nut/ups.conf << EOF
[${UPS_NAME}]
    driver = ${UPS_DRIVER}
    port   = ${UPS_PORT}
    desc   = "${UPS_DESC}"
EOF

info "Writing /etc/nut/upsd.conf..."
cat > /etc/nut/upsd.conf << EOF
LISTEN 127.0.0.1 3493
EOF

info "Writing /etc/nut/upsd.users..."
NUT_PASS="upsmon_$(head -c8 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c8)"
cat > /etc/nut/upsd.users << EOF
[upsmon]
    password = ${NUT_PASS}
    upsmon   = master
EOF

info "Writing /etc/nut/upsmon.conf..."
cat > /etc/nut/upsmon.conf << EOF
MONITOR ${UPS_NAME}@localhost 1 upsmon ${NUT_PASS} master
MINSUPPLIES 1
SHUTDOWNCMD "shutdown -h now"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
FINALDELAY 5
EOF

# Start NUT
info "Starting NUT..."
systemctl enable nut-server nut-client 2>/dev/null || true
upsdrvctl stop 2>/dev/null || true
sleep 1
upsdrvctl start 2>/dev/null && ok "NUT driver started" || warn "Driver failed to start — check USB connection"
sleep 1
systemctl restart nut-server 2>/dev/null || upsd 2>/dev/null || true
sleep 1

UPS_STATUS=$(upsc "${UPS_NAME}@localhost" ups.status 2>/dev/null || echo "")
if [[ -n "$UPS_STATUS" ]]; then
    ok "UPS is responding! Status: $UPS_STATUS"
    BAT=$(upsc "${UPS_NAME}@localhost" battery.charge 2>/dev/null || echo "?")
    RUNTIME=$(upsc "${UPS_NAME}@localhost" battery.runtime 2>/dev/null || echo "0")
    ok "Charge: ${BAT}% | Runtime: ~$(( ${RUNTIME:-0} / 60 )) min"
else
    warn "UPS not responding — check USB connection or permissions"
    warn "After install: upsc ${UPS_NAME}@localhost ups.status"
fi

# ══════════════════════════════════════════════
# BLOCK 3 — CLUSTER SETTINGS
# ══════════════════════════════════════════════

echo ""
hr
echo " BLOCK 3 — Cluster Settings"
hr

ask "Gossip API port [9213]:"
read -r INPUT_PORT
GOSSIP_PORT="${INPUT_PORT:-9213}"

ask "Quorum policy: majority / all / any [majority]:"
read -r INPUT_POLICY
QUORUM_POLICY="${INPUT_POLICY:-majority}"

ask "Shutdown delay after quorum reached (seconds) [300]:"
read -r INPUT_DELAY
SHUTDOWN_DELAY="${INPUT_DELAY:-300}"

# ══════════════════════════════════════════════
# BLOCK 4 — THRESHOLDS
# ══════════════════════════════════════════════

echo ""
hr
echo " BLOCK 4 — Shutdown Thresholds"
hr

ask "Critical UPS runtime — immediate shutdown (minutes) [9]:"
read -r INPUT_RUNTIME
CRITICAL_RUNTIME_MIN="${INPUT_RUNTIME:-9}"

ask "Critical battery level — immediate shutdown (%) [20]:"
read -r INPUT_BAT
CRITICAL_BATTERY="${INPUT_BAT:-20}"

# ══════════════════════════════════════════════
# BLOCK 5 — CLUSTER PEERS
# ══════════════════════════════════════════════

echo ""
hr
echo " BLOCK 5 — Cluster Peers"
hr
info "Peers are defined by hostname — IP is stored in /etc/hosts"
info "If a peer's IP changes, just update /etc/hosts — no config changes needed"
echo ""

PEERS=""
HOSTS_ENTRIES=""
PEER_NUM=1
while true; do
    ask "Peer $PEER_NUM hostname (press Enter to finish):"
    read -r PEER_HOST
    [[ -z "$PEER_HOST" ]] && break

    ask "IP address of $PEER_HOST:"
    read -r PEER_IP
    [[ -z "$PEER_IP" ]] && warn "No IP provided, skipping" && continue

    [[ -n "$PEERS" ]] && PEERS="${PEERS},"
    PEERS="${PEERS}${PEER_HOST}:${GOSSIP_PORT}"
    HOSTS_ENTRIES="${HOSTS_ENTRIES}${PEER_IP} ${PEER_HOST}\n"

    ok "Added peer: $PEER_HOST ($PEER_IP)"
    (( PEER_NUM++ ))
done

# ─────────────────────── Confirmation ────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Installation summary:"
echo ""
echo "   Server:          $HOST_NAME (IP auto-detected)"
echo "   Priority:        $SHUTDOWN_PRIORITY"
echo "   UPS:             ${UPS_NAME} (driver: ${UPS_DRIVER})"
echo "   Peers:           ${PEERS:-none}"
echo "   Gossip port:     $GOSSIP_PORT"
echo "   Quorum policy:   $QUORUM_POLICY"
echo "   Shutdown delay:  ${SHUTDOWN_DELAY}s"
echo "   Critical runtime: < ${CRITICAL_RUNTIME_MIN} min"
echo "   Critical charge:  < ${CRITICAL_BATTERY}%"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ask "Proceed with installation? [Y/n]:"
read -r CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && echo "Cancelled." && exit 0

# ─────────────────────── Dependencies ────────────────────────────

info "Installing remaining dependencies..."
apt-get install -y -qq netcat-traditional curl
ok "Dependencies installed"

# ─────────────────────── /etc/hosts ──────────────────────────────

if [[ -n "$HOSTS_ENTRIES" ]]; then
    info "Updating /etc/hosts..."
    cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"
    sed -i '/# ups-agent/d' /etc/hosts
    echo "" >> /etc/hosts
    printf "$HOSTS_ENTRIES" | while read -r line; do
        [[ -z "$line" ]] && continue
        HNAME=$(echo "$line" | awk '{print $2}')
        sed -i "/ ${HNAME}$/d" /etc/hosts
        echo "$line  # ups-agent" >> /etc/hosts
        ok "  /etc/hosts: $line"
    done
    ok "/etc/hosts updated"
fi

# ─────────────────────── Agent files ─────────────────────────────

info "Creating directories..."
mkdir -p /opt/ups-agent /etc/ups-agent

info "Copying agent files..."
cp "$SCRIPT_DIR/ups_agent.sh"    /opt/ups-agent/ups_agent.sh
cp "$SCRIPT_DIR/pre-shutdown.sh" /etc/ups-agent/pre-shutdown.sh
chmod +x /opt/ups-agent/ups_agent.sh
chmod +x /etc/ups-agent/pre-shutdown.sh
ok "Files copied"

# ─────────────────────── Agent config ────────────────────────────

info "Writing /etc/ups-agent/cluster.conf..."
cat > /etc/ups-agent/cluster.conf << EOF
# /etc/ups-agent/cluster.conf
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ─────────────────────────────────────────────────

HOST_NAME="${HOST_NAME}"
HOST_IP=""                   # empty = auto-detected at startup
HOST_ROLE="proxmox"
SHUTDOWN_PRIORITY=${SHUTDOWN_PRIORITY}

UPS_NAME="${UPS_NAME}"
UPS_HOST="localhost"
POLL_INTERVAL=30
CRITICAL_BATTERY=${CRITICAL_BATTERY}
CRITICAL_RUNTIME_MIN=${CRITICAL_RUNTIME_MIN}
WARNING_BATTERY=40

GOSSIP_PORT=${GOSSIP_PORT}
PEERS="${PEERS}"
PEER_TIMEOUT=120
QUORUM_POLICY="${QUORUM_POLICY}"
SHUTDOWN_DELAY=${SHUTDOWN_DELAY}

PRE_SHUTDOWN_SCRIPT="/etc/ups-agent/pre-shutdown.sh"
SHUTDOWN_COMMAND="shutdown -h now"
EOF
ok "Config written: /etc/ups-agent/cluster.conf"

# ─────────────────────── Systemd ─────────────────────────────────

info "Installing systemd unit..."
cp "$SCRIPT_DIR/ups-agent.service" /etc/systemd/system/ups-agent.service
systemctl daemon-reload
systemctl enable ups-agent
ok "Service enabled"

# ─────────────────────── Firewall ────────────────────────────────

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${GOSSIP_PORT}/tcp" comment "UPS Agent gossip" >/dev/null
    ok "Port $GOSSIP_PORT opened in ufw"
fi

# ─────────────────────── Start agent ─────────────────────────────

info "Starting agent..."
systemctl restart ups-agent
sleep 2

if systemctl is-active --quiet ups-agent; then
    ok "Agent is running"
else
    warn "Agent failed to start — check: journalctl -u ups-agent -n 20"
fi

# ─────────────────────── Final check ─────────────────────────────

info "Checking gossip API..."
sleep 1
RESPONSE=$(curl -s --max-time 3 "http://localhost:${GOSSIP_PORT}/status" 2>/dev/null || echo "")
if [[ -n "$RESPONSE" ]]; then
    ok "Gossip API is responding:"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
else
    warn "Gossip API not responding — check: curl http://localhost:${GOSSIP_PORT}/status"
fi

# ─────────────────────── Done ────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Installation complete!"
echo ""
echo "   Useful commands:"
echo "   systemctl status ups-agent"
echo "   tail -f /var/log/ups-agent.log"
echo "   upsc ${UPS_NAME}@localhost"
echo "   curl http://localhost:${GOSSIP_PORT}/status | python3 -m json.tool"
if [[ -n "$PEERS" ]]; then
    IFS=',' read -ra PEER_LIST <<< "$PEERS"
    for peer in "${PEER_LIST[@]}"; do
        echo "   curl http://${peer}/status | python3 -m json.tool"
    done
fi
echo ""
echo "   To update a peer's IP: edit /etc/hosts"
echo "   No agent restart required."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
