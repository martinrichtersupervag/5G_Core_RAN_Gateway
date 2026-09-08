# 5G_Core_RAN_Gateway
Proxmox Ansible automation for 5G Core and RAN gateway simulation with Amarisoft integration for DDS testbed communication

# Implementation Plan - 5G Core & RAN Gateway Infrastructure

Tento plán popisuje vytvoření kompletní struktury a konfigurací pro repozitář `5G_Core_RAN_Gateway`. Repozitář bude sloužit jako brána a testovací prostředí propojující Open5GS (5G Core), UERANSIM (gNodeB a UE simulace), síťové směrování (NAT/iptables), procesní orchestraci a simulaci kvality služeb (Linux TC / netem QoS profily pro 5G).

## User Review Required

> [!IMPORTANT]
> - **Výchozí IP adresy a síťová schémata**:
>   - Open5GS SBI/Control Plane: `127.0.0.X` (např. AMF NGAP na `127.0.0.5:38412`, SMF na `127.0.0.4`, UPF PFCP na `127.0.0.7`, GTP-U na `127.0.0.7:2152`).
>   - UE IP Pool: `10.45.0.0/16` s výchozí bránou `10.45.0.1` na rozhraní `ogstun`.
>   - PLMN / Identifikátory: MCC `999`, MNC `70`, TAC `1`, SST `1`, SD `0x000001`, APN/DNN `internet`.
> - **Skripty a proměnné prostředí**:
>   - Všechny skripty budou parametrizovatelné pomocí CLI argumentů i proměnných prostředí (např. `WAN_IFACE=eth0`, `TUN_IFACE=uesimtun0`, `UERANSIM_BIN_DIR`), aby fungovaly jak v lokálním testu, tak při nasazení přes Ansible playbook `site.yml`.

## Proposed Changes

Struktura projektu bude přesně odpovídat požadovanému stromu:

```text
5G_Core_RAN_Gateway/
├── open5gs/
│   ├── smf.yaml
│   └── upf.yaml
├── ueransim/
│   ├── gnb.yaml
│   └── ue.yaml
├── routing/
│   └── setup_gateway.sh
├── scripts/
│   └── start_5g_stack.sh
└── qos_profiles/
    └── apply_qos_policy.sh
```

---

### Open5GS Konfigurace (`open5gs/`)

#### [NEW] `open5gs/smf.yaml`
- Konfigurace Session Management Function v Open5GS.
- Definuje SBI rozhraní (HTTP/2), PFCP asociaci k UPF (`127.0.0.7:8805`), GTP-C.
- Definuje alokaci IP adres pro uživatelská zařízení (IP pool `10.45.0.0/16`), DNS servery (`8.8.8.8`, `1.1.1.1`) a mapování DNN/APN `internet` na daný UPF uzel.

#### [NEW] `open5gs/upf.yaml`
- Konfigurace User Plane Function v Open5GS.
- Definuje PFCP rozhraní (`127.0.0.7:8805`) a GTP-U uzel (`127.0.0.7:2152`).
- Nastavuje vytvoření a konfiguraci virtuálního tunelu `ogstun` a přiřazení IP rozsahu `10.45.0.1/16`.

---

### UERANSIM Konfigurace (`ueransim/`)

#### [NEW] `ueransim/gnb.yaml`
- Konfigurace 5G základnové stanice gNodeB v UERANSIM.
- Obsahuje nastavení PLMN (MCC: 999, MNC: 70), TAC (1), NCI a podporované slice (SST 1, SD 0x000001).
- Konfiguruje NGAP a GTP-U bind adresy a asociaci na Open5GS AMF (`127.0.0.5:38412`).

#### [NEW] `ueransim/ue.yaml`
- Konfigurace simulovaného uživatelského zařízení (UE).
- Definuje identitu UE (SUPI `imsi-999700000000001`, IMEI), bezpečnostní SIM parametry (K klíč, OPc klíč, AMF `8000`), šifrovací a integritní algoritmy.
- Definuje PDU Session parametry (APN `internet`, NSSAI SST 1 / SD 0x000001) a vazbu na `gnbSearchList`.

---

### Směrovací logika (`routing/`)

#### [NEW] `routing/setup_gateway.sh`
- Skript pro konfiguraci síťových rozhraní a směrování gateway brány:
  - Zapnutí `net.ipv4.ip_forward=1`.
  - Nastavení iptables pravidel pro NAT (MASQUERADE) mezi WAN/LAN rozhraním (`eth0`) a 5G tunelovým rozhraním (`ogstun` pro Core / `uesimtun0` pro UE).
  - Nastavení FORWARD pravidel s trackováním stavu (`ESTABLISHED,RELATED`).
  - Podpora pro příkazy `enable`, `disable`, `status` a parametry pro výběr rozhraní.

---

### Spouštěcí a orchestrální logika (`scripts/`)

#### [NEW] `scripts/start_5g_stack.sh`
- Spouštěcí skript pro UERANSIM komponenty:
  - Kontrola dostupnosti binárek `nr-gnb` a `nr-ue` a konfiguračních souborů.
  - Spuštění `nr-gnb` na pozadí s přesměrováním výstupu do logů (`/var/log/ueransim-gnb.log` nebo lokální složky).
  - Spuštění `nr-ue` na pozadí s přesměrováním výstupu do logů.
  - Aktivní čekání (healthcheck smyčka) na vytvoření virtuálního síťového rozhraní `uesimtun0` (s timeoutem).
  - Vypsání přidělené IP adresy a ověření konektivity.
  - Příkazy: `start`, `stop`, `status`, `restart`.

---

### Řízení kvality služeb (`qos_profiles/`)

#### [NEW] `qos_profiles/apply_qos_policy.sh`
- Skript pro Linux Traffic Control (`tc qdisc netem`):
  - Podpora profilů odpovídajících 5G 3GPP QoS / 5QI charakteristikám:
    - `embb`: Širokopásmový profil (např. 100 Mbps, 15ms zpoždění, 3ms jitter).
    - `urllc`: Ultra-spolehlivý nízkolatenční profil (např. 50 Mbps, 2ms zpoždění, 0.5ms jitter, 0% ztrátovost).
    - `miomt` / `mmtc`: Masivní IoT profil (např. 1 Mbps, 100ms zpoždění, 20ms jitter, 0.5% ztrátovost).
    - `degraded`: Zhoršené podmínky pro zátěžové testování (např. 80ms zpoždění, 25ms jitter, 3% packet loss).
    - `clear`: Kompletní reset tc pravidel na rozhraní.
    - `custom`: Možnost zadat vlastní parametry `--delay`, `--jitter`, `--loss`, `--rate`.
  - Validace rozhraní (výchozí `eth0`, možnost změny parametrem `-i <interface>`).

---

## Verification Plan

### Automatické a syntaktické testy
- Ověření validity YAML souborů (`yaml.safe_load` v Pythonu pro `open5gs/*.yaml` a `ueransim/*.yaml`).
- Ověření syntaktické správnosti bash skriptů pomocí `bash -n` (nebo `shellcheck` / python kontrola).
- Ověření spustitelnosti skriptů (`chmod +x` práva v git indexu).

### Funkční ověření parametrů
- Spuštění `routing/setup_gateway.sh --help`, `scripts/start_5g_stack.sh --help`, `qos_profiles/apply_qos_policy.sh --help` a ověření návratových kódů a formátu nápovědy.

