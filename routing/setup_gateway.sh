#!/usr/bin/env bash
# ==============================================================================
# setup_gateway.sh - 5G Core & RAN Gateway Network & NAT Configuration Script
# ==============================================================================
# Configures IP forwarding, iptables NAT/MASQUERADE, and routing tables
# between the physical/external network interface (e.g., eth0) and 5G tunnel
# virtual interfaces (ogstun on Open5GS UPF / uesimtun0 on UERANSIM UE).
# ==============================================================================

set -euo pipefail

# Default configuration values (can be overridden via environment variables or CLI flags)
WAN_IFACE="${WAN_IFACE:-eth0}"
OGSTUN_IFACE="${OGSTUN_IFACE:-ogstun}"
UESIMTUN_IFACE="${UESIMTUN_IFACE:-uesimtun0}"
SUBNET_5G="${SUBNET_5G:-10.45.0.0/16}"
GATEWAY_MODE="${GATEWAY_MODE:-all}" # Options: all, upf, ue

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Použití: $(basename "$0") [PŘÍKAZ] [VOLBY]

Příkazy:
  enable | start     Povolit IP forwarding a aplikovat iptables NAT/FORWARD pravidla
  disable | stop     Odstranit aplikovaná iptables pravidla
  status             Zobrazit aktuální stav forwardingu a iptables pravidel
  help | -h | --help Zobrazit tuto nápovědu

Volby:
  -w, --wan <rozhraní>   Fyzické / WAN rozhraní (výchozí: eth0, env: \$WAN_IFACE)
  -t, --tun <rozhraní>   Tunelové rozhraní (výchozí: uesimtun0 nebo ogstun)
  -s, --subnet <cidr>    5G UE IP rozsah (výchozí: 10.45.0.0/16, env: \$SUBNET_5G)
  -m, --mode <režim>     Režim brány: upf (Open5GS UPF), ue (UERANSIM UE), all (výchozí: all)

Příklady:
  sudo $(basename "$0") enable --wan eth0 --mode upf
  sudo $(basename "$0") enable --wan eth0 --mode ue
  sudo $(basename "$0") status
  sudo $(basename "$0") disable
EOF
    exit 0
}

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_error "Tento skript vyžaduje oprávnění uživatele root (spusťte s sudo)."
        exit 1
    fi
}

enable_ip_forward() {
    log_info "Aktivuji IPv4 forwarding (net.ipv4.ip_forward=1)..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    log_ok "IPv4 forwarding je aktivní."
}

# Helper to add iptables rule idempotently
iptables_add_rule() {
    local table="$1"
    shift
    if ! iptables -t "$table" -C "$@" 2>/dev/null; then
        iptables -t "$table" -A "$@"
        log_ok "Přidáno pravidlo [table: $table]: $*"
    else
        log_info "Pravidlo již existuje [table: $table]: $*"
    fi
}

# Helper to delete iptables rule safely
iptables_del_rule() {
    local table="$1"
    shift
    if iptables -t "$table" -C "$@" 2>/dev/null; then
        iptables -t "$table" -D "$@" 2>/dev/null || true
        log_ok "Odebráno pravidlo [table: $table]: $*"
    fi
}

setup_upf_nat() {
    log_info "Konfiguruji NAT a forwarding pro Open5GS UPF (rozhraní $OGSTUN_IFACE -> $WAN_IFACE)..."
    
    # Masquerade traffic from 5G UE subnet exiting WAN interface
    iptables_add_rule nat POSTROUTING -s "$SUBNET_5G" -o "$WAN_IFACE" -j MASQUERADE
    
    # Forwarding between ogstun and WAN
    iptables_add_rule filter FORWARD -i "$OGSTUN_IFACE" -o "$WAN_IFACE" -j ACCEPT
    iptables_add_rule filter FORWARD -i "$WAN_IFACE" -o "$OGSTUN_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

cleanup_upf_nat() {
    log_info "Odstraňuji NAT a forwarding pro Open5GS UPF ($OGSTUN_IFACE)..."
    iptables_del_rule nat POSTROUTING -s "$SUBNET_5G" -o "$WAN_IFACE" -j MASQUERADE
    iptables_del_rule filter FORWARD -i "$OGSTUN_IFACE" -o "$WAN_IFACE" -j ACCEPT
    iptables_del_rule filter FORWARD -i "$WAN_IFACE" -o "$OGSTUN_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

setup_ue_nat() {
    log_info "Konfiguruji NAT a forwarding pro UERANSIM UE (rozhraní $WAN_IFACE / LAN -> $UESIMTUN_IFACE)..."
    
    # Masquerade traffic routed via UE tunnel
    iptables_add_rule nat POSTROUTING -o "$UESIMTUN_IFACE" -j MASQUERADE
    
    # Forwarding between external/LAN and UE tunnel
    iptables_add_rule filter FORWARD -i "$WAN_IFACE" -o "$UESIMTUN_IFACE" -j ACCEPT
    iptables_add_rule filter FORWARD -i "$UESIMTUN_IFACE" -o "$WAN_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

cleanup_ue_nat() {
    log_info "Odstraňuji NAT a forwarding pro UERANSIM UE ($UESIMTUN_IFACE)..."
    iptables_del_rule nat POSTROUTING -o "$UESIMTUN_IFACE" -j MASQUERADE
    iptables_del_rule filter FORWARD -i "$WAN_IFACE" -o "$UESIMTUN_IFACE" -j ACCEPT
    iptables_del_rule filter FORWARD -i "$UESIMTUN_IFACE" -o "$WAN_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

cmd_enable() {
    check_root
    enable_ip_forward

    case "$GATEWAY_MODE" in
        upf)
            setup_upf_nat
            ;;
        ue)
            setup_ue_nat
            ;;
        all)
            setup_upf_nat
            setup_ue_nat
            ;;
        *)
            log_error "Neznámý režim: $GATEWAY_MODE (povolené: upf, ue, all)"
            exit 1
            ;;
    esac

    log_ok "Směrování a NAT brány byly úspěšně nakonfigurovány!"
}

cmd_disable() {
    check_root
    case "$GATEWAY_MODE" in
        upf)
            cleanup_upf_nat
            ;;
        ue)
            cleanup_ue_nat
            ;;
        all)
            cleanup_upf_nat
            cleanup_ue_nat
            ;;
    esac
    log_ok "Pravidla brány byla odstraněna."
}

cmd_status() {
    echo "=================================================================="
    echo "Stav síťové brány 5G Core & RAN"
    echo "=================================================================="
    echo -n "IPv4 Forwarding: "
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]]; then
        echo -e "${GREEN}POVOLEN (1)${NC}"
    else
        echo -e "${RED}ZAKÁZÁN (0)${NC}"
    fi

    echo -e "\n--- Síťová rozhraní ---"
    for iface in "$WAN_IFACE" "$OGSTUN_IFACE" "$UESIMTUN_IFACE"; do
        if ip link show "$iface" >/dev/null 2>&1; then
            local addr
            addr=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | paste -sd, - || echo "bez IPv4")
            echo -e " Rozhraní ${GREEN}$iface${NC}: AKTIVNÍ (IP: $addr)"
        else
            echo -e " Rozhraní ${YELLOW}$iface${NC}: NENALEZENO / NEAKTIVNÍ"
        fi
    done

    echo -e "\n--- Iptables NAT (POSTROUTING) ---"
    iptables -t nat -S POSTROUTING 2>/dev/null | grep -E 'MASQUERADE|ogstun|uesimtun|10.45' || echo "Žádná specifická pravidla nenalezena."

    echo -e "\n--- Iptables FORWARD ---"
    iptables -S FORWARD 2>/dev/null | grep -E 'ogstun|uesimtun|ACCEPT' || echo "Žádná specifická pravidla nenalezena."
    echo "=================================================================="
}

# Parse CLI arguments
COMMAND="enable"
if [[ $# -gt 0 ]]; then
    case "$1" in
        enable|start)   COMMAND="enable"; shift ;;
        disable|stop)   COMMAND="disable"; shift ;;
        status)         COMMAND="status"; shift ;;
        help|-h|--help) usage ;;
        -*)             ;; # Options start directly, default command is enable
        *)              log_error "Neznámý příkaz: $1"; usage ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--wan)
            WAN_IFACE="$2"
            shift 2
            ;;
        -t|--tun)
            OGSTUN_IFACE="$2"
            UESIMTUN_IFACE="$2"
            shift 2
            ;;
        -s|--subnet)
            SUBNET_5G="$2"
            shift 2
            ;;
        -m|--mode)
            GATEWAY_MODE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Neznámá volba: $1"
            usage
            ;;
    esac
done

case "$COMMAND" in
    enable)  cmd_enable ;;
    disable) cmd_disable ;;
    status)  cmd_status ;;
esac
