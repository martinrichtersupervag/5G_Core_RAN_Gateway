#!/usr/bin/env bash
# ==============================================================================
# apply_qos_policy.sh - 5G Traffic Control & QoS Emulation Script
# ==============================================================================
# Uses Linux Traffic Control (tc qdisc netem) on target network interfaces
# (default: eth0) to emulate 5G QoS profiles (delay, jitter, bandwidth, loss).
# ==============================================================================

set -euo pipefail

# Default interface
IFACE="${IFACE:-${WAN_IFACE:-eth0}}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Použití: $(basename "$0") [PROFIL | PŘÍKAZ] [VOLBY]

Dostupné profily:
  embb        Enhanced Mobile Broadband (100 Mbps, latence 15ms ± 3ms, ztrátovost 0.1%)
  urllc       Ultra-Reliable Low-Latency Communication (50 Mbps, latence 2ms ± 0.5ms, ztrátovost 0%)
  miomt       Massive IoT / mMTc (1 Mbps, latence 100ms ± 20ms, ztrátovost 0.5%)
  degraded    Zhoršené rádiové podmínky pro testování (20 Mbps, latence 80ms ± 25ms, ztráta 2%)
  custom      Vlastní parametry přes volby --delay, --jitter, --rate, --loss
  clear       Odstranit všechny tc qdisc politiky z rozhraní
  status      Zobrazit aktuální tc qdisc konfiguraci a statistiky na rozhraní

Volby:
  -i, --iface <rozhraní> Cílové síťové rozhraní (výchozí: eth0, env: \$IFACE)
  --delay <hodnota>      Zpoždění paketu (např. 20ms)
  --jitter <hodnota>     Variabilita zpoždění (např. 5ms)
  --rate <hodnota>       Omezení šířky pásma (např. 50mbit, 100mbit)
  --loss <procento>      Ztrátovost paketů v % (např. 0.5%)
  --duplicate <procento> Duplikace paketů v % (např. 0.2%)
  --corrupt <procento>   Poškození paketů v % (např. 0.1%)
  -h, --help             Zobrazit tuto nápovědu

Příklady:
  sudo $(basename "$0") urllc -i eth0
  sudo $(basename "$0") embb -i uesimtun0
  sudo $(basename "$0") custom -i eth0 --delay 25ms --jitter 4ms --rate 80mbit --loss 0.2%
  sudo $(basename "$0") status -i eth0
  sudo $(basename "$0") clear -i eth0
EOF
    exit 0
}

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_error "Tento skript vyžaduje oprávnění root (spusťte s sudo)."
        exit 1
    fi
}

check_tc() {
    if ! command -v tc >/dev/null 2>&1; then
        log_error "Nástroj 'tc' (iproute2) není nainstalován. Nainstalujte balíček 'iproute2'."
        exit 1
    fi
}

check_iface() {
    local iface="$1"
    if ! ip link show "$iface" >/dev/null 2>&1; then
        log_warn "Rozhraní '$iface' nebylo v systému nalezeno."
    fi
}

clear_qdisc() {
    local iface="$1"
    check_root
    check_tc
    log_info "Odstraňuji stávající qdisc pravidla z rozhraní '$iface'..."
    tc qdisc del dev "$iface" root 2>/dev/null || true
    log_ok "QoS pravidla na rozhraní '$iface' byla vyčištěna."
}

show_status() {
    local iface="$1"
    check_tc
    echo "=================================================================="
    echo -e "Aktuální QoS (Traffic Control) na rozhraní: ${CYAN}$iface${NC}"
    echo "=================================================================="
    if tc qdisc show dev "$iface" | grep -v "fq_codel\|noqueue" | grep -E "netem|tbf|htb" >/dev/null 2>&1; then
        tc -s qdisc show dev "$iface"
    else
        echo "Na rozhraní '$iface' není aplikována žádná emulace QoS (pouze výchozí qdisc):"
        tc qdisc show dev "$iface"
    fi
    echo "=================================================================="
}

apply_netem() {
    local iface="$1"
    shift
    local netem_args=("$@")

    check_root
    check_tc
    check_iface "$iface"

    # Clean existing root qdisc first
    tc qdisc del dev "$iface" root 2>/dev/null || true

    log_info "Aplikuji pravidlo netem na rozhraní '$iface':"
    log_info "  tc qdisc add dev $iface root netem ${netem_args[*]}"

    tc qdisc add dev "$iface" root netem "${netem_args[@]}"
    log_ok "QoS profil byl úspěšně aplikován na rozhraní '$iface'!"

    echo ""
    show_status "$iface"
}

# Profile parameters
CUSTOM_DELAY=""
CUSTOM_JITTER=""
CUSTOM_RATE=""
CUSTOM_LOSS=""
CUSTOM_DUP=""
CUSTOM_CORRUPT=""

PROFILE="urllc"

if [[ $# -gt 0 ]]; then
    case "$1" in
        embb|urllc|miomt|mmtc|degraded|impaired|custom|clear|status)
            PROFILE="$1"
            shift
            ;;
        help|-h|--help)
            usage
            ;;
        -*)
            ;;
        *)
            log_error "Neznámý profil nebo příkaz: $1"
            usage
            ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--iface)
            IFACE="$2"
            shift 2
            ;;
        --delay)
            CUSTOM_DELAY="$2"
            shift 2
            ;;
        --jitter)
            CUSTOM_JITTER="$2"
            shift 2
            ;;
        --rate)
            CUSTOM_RATE="$2"
            shift 2
            ;;
        --loss)
            CUSTOM_LOSS="$2"
            shift 2
            ;;
        --duplicate)
            CUSTOM_DUP="$2"
            shift 2
            ;;
        --corrupt)
            CUSTOM_CORRUPT="$2"
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

case "$PROFILE" in
    clear)
        clear_qdisc "$IFACE"
        ;;
    status)
        show_status "$IFACE"
        ;;
    embb)
        log_info "Nastavuji 5G eMBB profil (Enhanced Mobile Broadband)..."
        # 100 Mbps, 15ms latency, 3ms jitter, 0.1% loss
        apply_netem "$IFACE" delay 15ms 3ms rate 100mbit loss 0.1%
        ;;
    urllc)
        log_info "Nastavuji 5G URLLC profil (Ultra-Reliable Low-Latency Communication)..."
        # 50 Mbps, 2ms latency, 0.5ms jitter, 0% loss
        apply_netem "$IFACE" delay 2ms 0.5ms rate 50mbit
        ;;
    miomt|mmtc)
        log_info "Nastavuji 5G mIoT / mMTC profil (Massive Machine Type Communication)..."
        # 1 Mbps, 100ms latency, 20ms jitter, 0.5% loss
        apply_netem "$IFACE" delay 100ms 20ms rate 1mbit loss 0.5%
        ;;
    degraded|impaired)
        log_info "Nastavuji degradovaný 5G profil pro testování odolnosti..."
        # 20 Mbps, 80ms latency, 25ms jitter, 2% loss, 0.5% duplicate
        apply_netem "$IFACE" delay 80ms 25ms rate 20mbit loss 2.0% duplicate 0.5%
        ;;
    custom)
        log_info "Nastavuji uživatelsky definovaný QoS profil..."
        netem_args=()
        if [[ -n "$CUSTOM_DELAY" ]]; then
            netem_args+=(delay "$CUSTOM_DELAY")
            if [[ -n "$CUSTOM_JITTER" ]]; then
                netem_args+=("$CUSTOM_JITTER")
            fi
        fi
        if [[ -n "$CUSTOM_RATE" ]]; then
            netem_args+=(rate "$CUSTOM_RATE")
        fi
        if [[ -n "$CUSTOM_LOSS" ]]; then
            netem_args+=(loss "$CUSTOM_LOSS")
        fi
        if [[ -n "$CUSTOM_DUP" ]]; then
            netem_args+=(duplicate "$CUSTOM_DUP")
        fi
        if [[ -n "$CUSTOM_CORRUPT" ]]; then
            netem_args+=(corrupt "$CUSTOM_CORRUPT")
        fi

        if [[ ${#netem_args[@]} -eq 0 ]]; then
            log_error "Pro 'custom' profil musíte specifikovat alespoň jeden parametr (--delay, --rate, --loss atd.)."
            exit 1
        fi

        apply_netem "$IFACE" "${netem_args[@]}"
        ;;
esac
