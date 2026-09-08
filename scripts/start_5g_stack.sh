#!/usr/bin/env bash
# ==============================================================================
# start_5g_stack.sh - 5G RAN & UE Stack Lifecycle Manager
# ==============================================================================
# Launches UERANSIM nr-gnb (gNodeB) and nr-ue in background, monitors their
# initialization, and waits for the uesimtun0 virtual network interface.
# ==============================================================================

set -euo pipefail

# Script directory and project root discovery
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration parameters (overridable via environment variables or flags)
UERANSIM_DIR="${UERANSIM_DIR:-/opt/ueransim}"
GNB_CONFIG="${GNB_CONFIG:-$PROJECT_ROOT/ueransim/gnb.yaml}"
UE_CONFIG="${UE_CONFIG:-$PROJECT_ROOT/ueransim/ue.yaml}"
TUN_IFACE="${TUN_IFACE:-uesimtun0}"
TIMEOUT="${TIMEOUT:-30}"

LOG_DIR="${LOG_DIR:-/var/log/ueransim}"
PID_DIR="${PID_DIR:-/run/ueransim}"

GNB_PID_FILE="$PID_DIR/nr-gnb.pid"
UE_PID_FILE="$PID_DIR/nr-ue.pid"
GNB_LOG="$LOG_DIR/gnb.log"
UE_LOG="$LOG_DIR/ue.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Použití: $(basename "$0") [PŘÍKAZ] [VOLBY]

Příkazy:
  start              Spustit nr-gnb a nr-ue a počkat na uesimtun0
  stop               Zastavit spuštěný 5G stack (nr-ue a nr-gnb)
  restart            Restartovat celý 5G stack
  status             Zkontrolovat stav běžících procesů a tunelového rozhraní
  wait-tun           Pouze čekat na inicializaci tunelového rozhraní
  help | -h | --help Zobrazit tuto nápovědu

Volby:
  --ueransim-dir <cesta>  Kořenový adresář instalace UERANSIM (výchozí: /opt/ueransim)
  --gnb-config <cesta>    Cesta k souboru gnb.yaml
  --ue-config <cesta>     Cesta k souboru ue.yaml
  --tun <rozhraní>        Očekávané jméno tunelového rozhraní (výchozí: uesimtun0)
  --timeout <sekundy>     Timeout čekání na tunelové rozhraní (výchozí: 30)
  --log-dir <cesta>       Adresář pro logy (výchozí: /var/log/ueransim)

Příklady:
  sudo $(basename "$0") start
  sudo $(basename "$0") status
  sudo $(basename "$0") stop
EOF
    exit 0
}

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_error "Tento skript vyžaduje oprávnění root pro vytvoření TUN rozhraní."
        exit 1
    fi
}

find_binary() {
    local bin_name="$1"
    local bin_path=""

    if [[ -x "$UERANSIM_DIR/build/$bin_name" ]]; then
        bin_path="$UERANSIM_DIR/build/$bin_name"
    elif [[ -x "$UERANSIM_DIR/$bin_name" ]]; then
        bin_path="$UERANSIM_DIR/$bin_name"
    elif command -v "$bin_name" >/dev/null 2>&1; then
        bin_path="$(command -v "$bin_name")"
    fi

    echo "$bin_path"
}

init_dirs() {
    mkdir -p "$LOG_DIR" "$PID_DIR"
}

is_running() {
    local pid_file="$1"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

wait_for_tunnel() {
    local timeout="$1"
    local iface="$2"
    local elapsed=0

    log_info "Čekám na inicializaci virtuálního síťového rozhraní '$iface' (max ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        if ip link show "$iface" >/dev/null 2>&1; then
            # Verify if interface is UP
            local state
            state=$(ip -o link show "$iface" | awk '{print $9}')
            log_ok "Rozhraní '$iface' bylo detekováno! (Stav: $state)"

            # Wait briefly for IPv4 allocation
            local ip_addr=""
            for _ in {1..10}; do
                ip_addr=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
                if [[ -n "$ip_addr" ]]; then
                    break
                fi
                sleep 0.5
            done

            if [[ -n "$ip_addr" ]]; then
                log_ok "5G UE získalo IP adresu: ${GREEN}$ip_addr${NC}"
            else
                log_warn "Rozhraní existuje, ale dosud nemá přidělenou IPv4 adresu."
            fi
            return 0
        fi

        sleep 1
        ((elapsed++))
        echo -n "."
    done

    echo ""
    log_error "Timeout (${timeout}s) vypršel! Rozhraní '$iface' nebylo vytvořeno."
    log_error "Zkontrolujte logy v: $UE_LOG a $GNB_LOG"
    return 1
}

start_stack() {
    check_root
    init_dirs

    local gnb_bin ue_bin
    gnb_bin=$(find_binary "nr-gnb")
    ue_bin=$(find_binary "nr-ue")

    if [[ -z "$gnb_bin" ]]; then
        log_error "Binárka 'nr-gnb' nebyla nalezena v \$UERANSIM_DIR ($UERANSIM_DIR) ani v \$PATH."
        exit 1
    fi
    if [[ -z "$ue_bin" ]]; then
        log_error "Binárka 'nr-ue' nebyla nalezena v \$UERANSIM_DIR ($UERANSIM_DIR) ani v \$PATH."
        exit 1
    fi

    if [[ ! -f "$GNB_CONFIG" ]]; then
        log_error "Konfigurační soubor gNodeB nenalezen: $GNB_CONFIG"
        exit 1
    fi
    if [[ ! -f "$UE_CONFIG" ]]; then
        log_error "Konfigurační soubor UE nenalezen: $UE_CONFIG"
        exit 1
    fi

    # 1. Start nr-gnb
    if is_running "$GNB_PID_FILE"; then
        log_warn "nr-gnb již běží (PID: $(cat "$GNB_PID_FILE"))."
    else
        log_info "Spouštím nr-gnb s konfigurací: $GNB_CONFIG"
        nohup "$gnb_bin" -c "$GNB_CONFIG" > "$GNB_LOG" 2>&1 &
        local gnb_pid=$!
        echo "$gnb_pid" > "$GNB_PID_FILE"
        sleep 2

        if ! kill -0 "$gnb_pid" 2>/dev/null; then
            log_error "nr-gnb neočekávaně skončil! Poslední řádky logu ($GNB_LOG):"
            tail -n 20 "$GNB_LOG" >&2
            exit 1
        fi
        log_ok "nr-gnb úspěšně spuštěn (PID: $gnb_pid)."
    fi

    # 2. Start nr-ue
    if is_running "$UE_PID_FILE"; then
        log_warn "nr-ue již běží (PID: $(cat "$UE_PID_FILE"))."
    else
        log_info "Spouštím nr-ue s konfigurací: $UE_CONFIG"
        nohup "$ue_bin" -c "$UE_CONFIG" > "$UE_LOG" 2>&1 &
        local ue_pid=$!
        echo "$ue_pid" > "$UE_PID_FILE"
        sleep 2

        if ! kill -0 "$ue_pid" 2>/dev/null; then
            log_error "nr-ue neočekávaně skončil! Poslední řádky logu ($UE_LOG):"
            tail -n 20 "$UE_LOG" >&2
            exit 1
        fi
        log_ok "nr-ue úspěšně spuštěn (PID: $ue_pid)."
    fi

    # 3. Wait for uesimtun0
    if wait_for_tunnel "$TIMEOUT" "$TUN_IFACE"; then
        echo "=================================================================="
        log_ok "5G Stack byl úspěšně nastartován a tunel '$TUN_IFACE' je připraven!"
        echo "=================================================================="
    else
        exit 1
    fi
}

stop_process() {
    local name="$1"
    local pid_file="$2"

    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_info "Zastavuji $name (PID: $pid)..."
            kill -TERM "$pid" 2>/dev/null || true

            # Grace period
            for _ in {1..10}; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    break
                fi
                sleep 0.5
            done

            if kill -0 "$pid" 2>/dev/null; then
                log_warn "$name neodpovídá na SIGTERM, posílám SIGKILL..."
                kill -KILL "$pid" 2>/dev/null || true
            fi
            log_ok "$name zastaven."
        else
            log_info "$name neběží."
        fi
        rm -f "$pid_file"
    else
        log_info "$name nemá aktivní PID soubor."
    fi
}

stop_stack() {
    check_root
    log_info "Zastavuji 5G RAN & UE Stack..."
    stop_process "nr-ue" "$UE_PID_FILE"
    stop_process "nr-gnb" "$GNB_PID_FILE"
    log_ok "5G Stack byl zastaven."
}

status_stack() {
    echo "=================================================================="
    echo "Stav 5G RAN & UE Stacku"
    echo "=================================================================="

    echo -n "Proces nr-gnb: "
    if is_running "$GNB_PID_FILE"; then
        echo -e "${GREEN}BĚŽÍ${NC} (PID: $(cat "$GNB_PID_FILE"))"
    else
        echo -e "${RED}NEBĚŽÍ${NC}"
    fi

    echo -n "Proces nr-ue:  "
    if is_running "$UE_PID_FILE"; then
        echo -e "${GREEN}BĚŽÍ${NC} (PID: $(cat "$UE_PID_FILE"))"
    else
        echo -e "${RED}NEBĚŽÍ${NC}"
    fi

    echo -n "Tunelové rozhraní '$TUN_IFACE': "
    if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
        local ip_addr
        ip_addr=$(ip -4 -o addr show "$TUN_IFACE" 2>/dev/null | awk '{print $4}' || echo "bez IP")
        echo -e "${GREEN}AKTIVNÍ${NC} (IP: $ip_addr)"
    else
        echo -e "${RED}NEEXISTUJE${NC}"
    fi

    echo "=================================================================="
}

COMMAND="start"
if [[ $# -gt 0 ]]; then
    case "$1" in
        start)          COMMAND="start"; shift ;;
        stop)           COMMAND="stop"; shift ;;
        restart)        COMMAND="restart"; shift ;;
        status)         COMMAND="status"; shift ;;
        wait-tun)       COMMAND="wait-tun"; shift ;;
        help|-h|--help) usage ;;
        -*)             ;;
        *)              log_error "Neznámý příkaz: $1"; usage ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ueransim-dir) UERANSIM_DIR="$2"; shift 2 ;;
        --gnb-config)   GNB_CONFIG="$2"; shift 2 ;;
        --ue-config)    UE_CONFIG="$2"; shift 2 ;;
        --tun)          TUN_IFACE="$2"; shift 2 ;;
        --timeout)      TIMEOUT="$2"; shift 2 ;;
        --log-dir)      LOG_DIR="$2"; GNB_LOG="$LOG_DIR/gnb.log"; UE_LOG="$LOG_DIR/ue.log"; shift 2 ;;
        -h|--help)      usage ;;
        *)              log_error "Neznámá volba: $1"; usage ;;
    esac
done

case "$COMMAND" in
    start)
        start_stack
        ;;
    stop)
        stop_stack
        ;;
    restart)
        stop_stack
        sleep 2
        start_stack
        ;;
    status)
        status_stack
        ;;
    wait-tun)
        wait_for_tunnel "$TIMEOUT" "$TUN_IFACE"
        ;;
esac
