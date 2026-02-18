#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║        🚀 PSIPHON CONDUIT MANAGER v1.1.0-Mac                      ║
# ║                                                                   ║
# ║  One-click setup for Psiphon Conduit                              ║
# ║                                                                   ║
# ║  • Installs Docker (if needed)                                    ║
# ║  • Runs Conduit in Docker with live stats                         ║
# ║  • Auto-start on boot via systemd/OpenRC/SysVinit                 ║
# ║  • Easy management via CLI or interactive menu                    ║
# ║                                                                   ║
# ║  GitHub: https://github.com/Psiphon-Inc/conduit                   ║
# ╚═══════════════════════════════════════════════════════════════════╝
# core engine: https://github.com/Psiphon-Labs/psiphon-tunnel-core
# Usage:
# curl -sL https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh | sudo bash
#
# Reference: https://github.com/ssmirr/conduit/releases/tag/d8522a8
# Conduit CLI options:
#   -m, --max-clients int   maximum number of proxy clients (1-1000) (default 200)
#   -b, --bandwidth float   bandwidth limit per peer in Mbps (1-40, or -1 for unlimited) (default 5)
#   -v, --verbose           increase verbosity (-v for verbose, -vv for debug)
#

set -e

# Ensure we're running in bash (not sh/dash)
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0"
    exit 1
fi

VERSION="1.1.0-Mac"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/conduit}"
# BACKUP_DIR depends on INSTALL_DIR and may be overridden during OS detection (e.g. macOS).
BACKUP_DIR=""
STATS_FILE="/home/conduit/data/conduit_stats.json"

# Helper function to fix file ownership when running as root
# This prevents permission issues when scripts run with sudo
fix_file_ownership() {
    local file="$1"
    [ ! -e "$file" ] && return 0
    
    # Only fix if running as root via sudo
    if [ "$EUID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
        chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$file" 2>/dev/null || true
    fi
}

# Helper function to ensure directory exists with correct ownership
ensure_dir() {
    local dir="$1"
    mkdir -p "$dir" 2>/dev/null || true
    fix_file_ownership "$dir"
}
FORCE_REINSTALL=false
PERSIST_DIR="$INSTALL_DIR/traffic_stats"
CONNECTION_HISTORY_FILE="$PERSIST_DIR/connection_history"
CONNECTION_HISTORY_START_FILE="$PERSIST_DIR/connection_history_start"
PEAK_CONNECTIONS_FILE="$PERSIST_DIR/peak_connections"
TRACKER_ENABLED=true
TRACKER_PID_FILE="$INSTALL_DIR/tracker.pid"
TRACKER_LOG_FILE="$INSTALL_DIR/tracker.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    local inner_width=67
    local title="🚀  PSIPHON CONDUIT MANAGER v${VERSION}"
    local title_len=${#title}
    local emoji_width=0
    if [[ "$title" == *"🚀"* ]]; then
        emoji_width=1
    fi
    local visible_len=$((title_len + emoji_width))
    local pad_total=$((inner_width - visible_len))
    [ "$pad_total" -lt 0 ] && pad_total=0
    local pad_left=$((pad_total / 2))
    local pad_right=$((pad_total - pad_left))
    printf "║%*s%s%*s║\n" "$pad_left" "" "$title" "$pad_right" ""
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║       Help users access the open internet during shutdowns        ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

check_root() {
    # On macOS we support user installs (no root) by default, and we *avoid* sudo because Homebrew
    # refuses to run as root.
    if [ "${OS_FAMILY:-unknown}" = "macos" ]; then
        if [ "$EUID" -eq 0 ]; then
            log_error "Do not run this script with sudo on macOS."
            log_info "Homebrew will refuse to install packages as root."
            log_info "Run it like this instead:"
            log_info "  bash $0"
            log_info ""
            log_info "If you downloaded via curl, remove sudo:"
            log_info "  curl -sL https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit.sh | bash"
            exit 1
        fi
        return 0
    fi

    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    OS="unknown"
    OS_VERSION="unknown"
    OS_FAMILY="unknown"
    HAS_SYSTEMD=false
    PKG_MANAGER="unknown"
    
    # Detect OS from /etc/os-release
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        OS="macos"
        OS_FAMILY="macos"
        OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
        PKG_MANAGER="brew"
        HAS_SYSTEMD=false
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        OS_VERSION="${VERSION_ID:-unknown}"
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/arch-release ]; then
        OS="arch"
    elif [ -f /etc/SuSE-release ] || [ -f /etc/SUSE-brand ]; then
        OS="opensuse"
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi
    
    # Determine OS family and package manager
    case "$OS" in
        macos)
            OS_FAMILY="macos"
            PKG_MANAGER="brew"
            ;;
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali|raspbian)
            OS_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        rhel|centos|fedora|rocky|almalinux|oracle|amazon|amzn)
            OS_FAMILY="rhel"
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro|endeavouros|garuda)
            OS_FAMILY="arch"
            PKG_MANAGER="pacman"
            ;;
        opensuse|opensuse-leap|opensuse-tumbleweed|sles)
            OS_FAMILY="suse"
            PKG_MANAGER="zypper"
            ;;
        alpine)
            OS_FAMILY="alpine"
            PKG_MANAGER="apk"
            ;;
        *)
            OS_FAMILY="unknown"
            PKG_MANAGER="unknown"
            ;;
    esac
    
    # Check for systemd
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        HAS_SYSTEMD=true
    fi

    # macOS default install dir: avoid requiring sudo for /opt
    if [ "$OS_FAMILY" = "macos" ] && [ "$INSTALL_DIR" = "/opt/conduit" ]; then
        INSTALL_DIR="$HOME/.conduit"
    fi
    BACKUP_DIR="$INSTALL_DIR/backups"
    
    log_info "Detected: $OS ($OS_FAMILY family), Package manager: $PKG_MANAGER"

    if command -v podman &>/dev/null && ! command -v docker &>/dev/null; then
        log_warn "Podman detected. This script is optimized for Docker."
        log_warn "If installation fails, consider installing 'docker-ce' manually."
    fi
}

ensure_install_dir_writable() {
    # On macOS we aim for a fully non-sudo install. If a previous sudo run created a root-owned
    # directory (common), fall back to a user-writable install dir automatically.
    if [ "$OS_FAMILY" != "macos" ]; then
        return 0
    fi

    mkdir -p "$INSTALL_DIR" 2>/dev/null || true

    if [ -w "$INSTALL_DIR" ]; then
        return 0
    fi

    log_warn "Install directory is not writable: $INSTALL_DIR"
    log_warn "This usually happens if you previously ran the installer with sudo."

    local fallback_dir="$HOME/.conduit-user"
    local fallback_dir_alt="$HOME/.conduit-user-$USER"
    log_info "Switching to a user-writable install directory: $fallback_dir"

    INSTALL_DIR="$fallback_dir"
    BACKUP_DIR="$INSTALL_DIR/backups"

    mkdir -p "$INSTALL_DIR" 2>/dev/null || true
    chmod u+rwx "$INSTALL_DIR" 2>/dev/null || true
    if [ ! -w "$INSTALL_DIR" ]; then
        log_warn "Fallback dir is still not writable: $INSTALL_DIR"
        log_info "Trying an alternate fallback: $fallback_dir_alt"
        INSTALL_DIR="$fallback_dir_alt"
        BACKUP_DIR="$INSTALL_DIR/backups"
        mkdir -p "$INSTALL_DIR" 2>/dev/null || true
        chmod u+rwx "$INSTALL_DIR" 2>/dev/null || true
    fi

    if [ ! -w "$INSTALL_DIR" ]; then
        log_error "Install directory is still not writable: $INSTALL_DIR"
        log_info "Please fix permissions or choose a different INSTALL_DIR."
        log_info "Example (fix old dir ownership):"
        log_info "  sudo chown -R \"$(id -u):$(id -g)\" \"$HOME/.conduit\""
        exit 1
    fi
}

install_package() {
    local package="$1"
    log_info "Installing $package..."
    
    case "$PKG_MANAGER" in
        brew)
            if [ "$EUID" -eq 0 ]; then
                log_error "Homebrew cannot be run as root on macOS."
                log_info "Please rerun without sudo."
                return 1
            fi
            if ! command -v brew &>/dev/null; then
                log_error "Homebrew is required on macOS to install dependencies."
                log_info "Install Homebrew from: https://brew.sh/"
                return 1
            fi
            if brew install "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package via Homebrew"
                return 1
            fi
            ;;
        apt)
            # Make update failure non-fatal but log it
            apt-get update -q || log_warn "apt-get update failed, attempting to install regardless..."
            if apt-get install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        dnf)
            if dnf install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        yum)
            if yum install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        pacman)
            if pacman -Sy --noconfirm "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        zypper)
            if zypper install -y -n "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        apk)
            if apk add --no-cache "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        *)
            log_warn "Unknown package manager. Please install $package manually."
            return 1
            ;;
    esac
}

check_dependencies() {
    # Check for bash
    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! command -v bash &>/dev/null; then
            log_info "Installing bash (required for this script)..."
            apk add --no-cache bash 2>/dev/null
        fi
    fi
    
    # Check for curl
    if ! command -v curl &>/dev/null; then
        install_package curl || log_warn "Could not install curl automatically"
    fi

    # macOS: ensure modern bash (system bash is 3.2 without associative arrays)
    if [ "$OS_FAMILY" = "macos" ]; then
        local bash_path
        bash_path=$(command -v bash || true)
        local bash_major=0
        if [ -n "$bash_path" ]; then
            bash_major=$(bash -c 'ver=${BASH_VERSINFO[0]:-0}; echo "${ver:-0}"' 2>/dev/null || echo 0)
        fi
        if [ "$bash_major" -lt 4 ]; then
            log_info "Installing modern bash via Homebrew (required for associative arrays)..."
            install_package bash || log_warn "Could not install modern bash; macOS peers view may fail"
        fi
    fi
    
    # Check for basic tools
    if ! command -v awk &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package gawk || log_warn "Could not install gawk" ;;
            apk) install_package gawk || log_warn "Could not install gawk" ;;
            *) install_package awk || log_warn "Could not install awk" ;;
        esac
    fi
    
    # Check for free command (Linux). On macOS we use other methods for RAM stats.
    if [ "$OS_FAMILY" != "macos" ] && ! command -v free &>/dev/null; then
        case "$PKG_MANAGER" in
            apt|dnf|yum) install_package procps || log_warn "Could not install procps" ;;
            pacman) install_package procps-ng || log_warn "Could not install procps" ;;
            zypper) install_package procps || log_warn "Could not install procps" ;;
            apk) install_package procps || log_warn "Could not install procps" ;;
        esac
    fi

    # Check for tput (ncurses)
    if ! command -v tput &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package ncurses-bin || log_warn "Could not install ncurses-bin" ;;
            apk) install_package ncurses || log_warn "Could not install ncurses" ;;
            *) install_package ncurses || log_warn "Could not install ncurses" ;;
        esac
    fi

    # Check for tcpdump
    if ! command -v tcpdump &>/dev/null; then
        install_package tcpdump || log_warn "Could not install tcpdump automatically"
    fi

    # Check for GeoIP tools
    if ! command -v geoiplookup &>/dev/null; then
        case "$PKG_MANAGER" in
            brew)
                # macOS: implement GeoIP via DB-IP Lite MMDB + mmdblookup (libmaxminddb)
                if ! command -v mmdblookup &>/dev/null; then
                    install_package libmaxminddb || {
                        log_error "GeoIP lookup is required for peers-by-country on macOS."
                        log_error "Failed to install libmaxminddb (mmdblookup)."
                        exit 1
                    }
                fi

                # Ensure DB-IP Lite Country DB is present (optional unless peers-by-country is used)
                ensure_geoip_db_macos
                ;;
            apt) 
                # geoip-bin and geoip-database for newer systems
                install_package geoip-bin || log_warn "Could not install geoip-bin"
                install_package geoip-database || log_warn "Could not install geoip-database"
                ;;
            dnf|yum) 
                # On RHEL/CentOS
                if ! rpm -q epel-release &>/dev/null; then
                    log_info "Enabling EPEL repository for GeoIP..."
                    $PKG_MANAGER install -y epel-release &>/dev/null || true
                fi
                install_package GeoIP || log_warn "Could not install GeoIP."
                ;;
            pacman) install_package geoip || log_warn "Could not install geoip." ;;
            zypper) install_package GeoIP || log_warn "Could not install GeoIP." ;;
            apk) install_package geoip || log_warn "Could not install geoip." ;;
            *) log_warn "Could not install geoiplookup automatically" ;;
        esac
    fi
}

ensure_geoip_db_macos() {
    # Ensure DB-IP Lite Country DB exists for mmdblookup.
    # Optional unless peers-by-country is used.
    if [ "$OS_FAMILY" != "macos" ]; then
        return 0
    fi

    local geoip_dir="$INSTALL_DIR/geoip"
    local mmdb_path="$geoip_dir/dbip-country-lite.mmdb"
    mkdir -p "$geoip_dir"

    if [ -f "$mmdb_path" ]; then
        return 0
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                 GEOIP DATABASE (macOS)                         ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "To show peers by country on macOS, we use the free DB-IP Lite Country database."
    echo "No account or license key is required."
    echo ""
    echo -e "  Source: ${YELLOW}https://db-ip.com/db/ip-to-country-lite${NC}"
    echo ""
    read -p "Download DB-IP Lite database now? [y/N] " geoip_confirm < /dev/tty || true
    if [[ ! "$geoip_confirm" =~ ^[Yy] ]]; then
        log_warn "Skipping GeoIP database setup."
        log_info "You can rerun the installer later to enable peers-by-country on macOS."
        return 0
    fi

    log_info "Downloading DB-IP Lite Country database..."
    local tmpdir
    tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t conduit_geoip)"
    local download_path="$tmpdir/dbip-country-lite.mmdb.gz"
    local download_ok=0
    local year_month=""
    local url=""

    year_month="$(date +%Y-%m 2>/dev/null || echo "")"
    if [ -n "$year_month" ]; then
        url="https://download.db-ip.com/free/dbip-country-lite-${year_month}.mmdb.gz"
        if curl -fL -sS "$url" -o "$download_path"; then
            download_ok=1
        fi
    fi

    if [ "$download_ok" -ne 1 ]; then
        local prev_year_month=""
        if date -v -1m +%Y-%m >/dev/null 2>&1; then
            prev_year_month="$(date -v -1m +%Y-%m 2>/dev/null || echo "")"
        elif date -d "1 month ago" +%Y-%m >/dev/null 2>&1; then
            prev_year_month="$(date -d "1 month ago" +%Y-%m 2>/dev/null || echo "")"
        fi
        if [ -n "$prev_year_month" ]; then
            url="https://download.db-ip.com/free/dbip-country-lite-${prev_year_month}.mmdb.gz"
            if curl -fL -sS "$url" -o "$download_path"; then
                download_ok=1
            fi
        fi
    fi

    if [ "$download_ok" -ne 1 ]; then
        log_error "Failed to download DB-IP Lite database."
        rm -rf "$tmpdir" 2>/dev/null || true
        log_warn "Skipping GeoIP database setup."
        return 0
    fi

    local extracted_mmdb="$tmpdir/dbip-country-lite.mmdb"
    local file_type=""
    if command -v file &>/dev/null; then
        file_type="$(file -b "$download_path" 2>/dev/null || true)"
    fi

    if [ -z "$file_type" ] && command -v od &>/dev/null; then
        local magic
        magic="$(od -An -t x1 -N 4 "$download_path" 2>/dev/null | tr -d ' \n')"
        case "$magic" in
            504b0304) file_type="zip" ;;
            1f8b08*) file_type="gzip" ;;
            3c21444f|3c68746d) file_type="html" ;;
        esac
    fi

    case "$file_type" in
        *HTML*|*html*)
            log_error "Download did not return a database file (HTML response)."
            rm -rf "$tmpdir" 2>/dev/null || true
            log_warn "Skipping GeoIP database setup."
            return 0
            ;;
        *gzip*|*GZIP*|*gz*)
            if ! command -v gzip &>/dev/null; then
                log_error "Gzip archive detected but gzip is not available."
                rm -rf "$tmpdir" 2>/dev/null || true
                log_warn "Skipping GeoIP database setup."
                return 0
            fi
            if ! gzip -dc "$download_path" > "$extracted_mmdb" 2>/dev/null; then
                log_error "Failed to extract DB-IP Lite gzip archive."
                rm -rf "$tmpdir" 2>/dev/null || true
                log_warn "Skipping GeoIP database setup."
                return 0
            fi
            ;;
        *Zip*|*zip*)
            if command -v unzip &>/dev/null; then
                if ! unzip -p "$download_path" "*.mmdb" > "$extracted_mmdb" 2>/dev/null; then
                    log_error "Failed to extract DB-IP Lite zip archive."
                    rm -rf "$tmpdir" 2>/dev/null || true
                    log_warn "Skipping GeoIP database setup."
                    return 0
                fi
            elif command -v python3 &>/dev/null; then
                if ! python3 - "$download_path" "$extracted_mmdb" <<'PY'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    for name in z.namelist():
        if name.lower().endswith(".mmdb"):
            with z.open(name) as f, open(dst, "wb") as out:
                out.write(f.read())
            sys.exit(0)
sys.exit(1)
PY
                then
                    log_error "Failed to extract DB-IP Lite zip archive."
                    rm -rf "$tmpdir" 2>/dev/null || true
                    log_warn "Skipping GeoIP database setup."
                    return 0
                fi
            else
                log_error "Zip archive detected but unzip/python3 not available."
                rm -rf "$tmpdir" 2>/dev/null || true
                log_warn "Skipping GeoIP database setup."
                return 0
            fi
            ;;
        *)
            # Assume direct MMDB download
            cp "$download_path" "$extracted_mmdb" 2>/dev/null || true
            ;;
    esac

    if [ ! -f "$extracted_mmdb" ]; then
        log_error "DB-IP Lite MMDB not found in downloaded archive."
        rm -rf "$tmpdir" 2>/dev/null || true
        log_warn "Skipping GeoIP database setup."
        return 0
    fi

    if ! cp "$extracted_mmdb" "$mmdb_path"; then
        log_error "Failed to install GeoIP database to: $mmdb_path"
        rm -rf "$tmpdir" 2>/dev/null || true
        log_warn "Skipping GeoIP database setup."
        return 0
    fi

    rm -rf "$tmpdir" 2>/dev/null || true
    log_success "GeoIP database installed: $mmdb_path"
}

get_ram_mb() {
    # Get RAM in MB
    local ram=""

    # macOS
    if [ "$OS_FAMILY" = "macos" ]; then
        local bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "")
        if [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ] 2>/dev/null; then
            ram=$((bytes / 1024 / 1024))
        fi
    fi
    
    # Try free command first
    if command -v free &>/dev/null; then
        ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    fi
    
    # Fallback: parse /proc/meminfo
    if [ -z "$ram" ] || [ "$ram" = "0" ]; then
        if [ -f /proc/meminfo ]; then
            local kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
            if [ -n "$kb" ]; then
                ram=$((kb / 1024))
            fi
        fi
    fi
    
    # Ensure minimum of 1
    if [ -z "$ram" ] || [ "$ram" -lt 1 ] 2>/dev/null; then
        echo 1
    else
        echo "$ram"
    fi
}

get_cpu_cores() {
    local cores=1
    if [ "$OS_FAMILY" = "macos" ]; then
        cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
    elif command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c ^processor /proc/cpuinfo)
    fi
    
    # Safety check
    if [ -z "$cores" ] || [ "$cores" -lt 1 ] 2>/dev/null; then
        echo 1
    else
        echo "$cores"
    fi
}

calculate_recommended_clients() {
    local cores=$(get_cpu_cores)
    # Logic: 100 clients per CPU core, max 1000
    local recommended=$((cores * 100))
    if [ "$recommended" -gt 1000 ]; then
        echo 1000
    else
        echo "$recommended"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Interactive Setup
#═══════════════════════════════════════════════════════════════════════

prompt_settings() {
    local ram_mb=$(get_ram_mb)
    local cpu_cores=$(get_cpu_cores)
    local recommended=$(calculate_recommended_clients)
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    CONDUIT CONFIGURATION                      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Server Info:${NC}"
    echo -e "    CPU Cores: ${GREEN}${cpu_cores}${NC}"
    if [ "$ram_mb" -ge 1000 ]; then
        local ram_gb=$(awk "BEGIN {printf \"%.1f\", $ram_mb/1024}")
        echo -e "    RAM: ${GREEN}${ram_gb} GB${NC}"
    else
        echo -e "    RAM: ${GREEN}${ram_mb} MB${NC}"
    fi
    echo -e "    Recommended max-clients: ${GREEN}${recommended}${NC}"
    echo ""
    echo -e "  ${BOLD}Conduit Options:${NC}"
    echo -e "    ${YELLOW}--max-clients${NC}  Maximum proxy clients (1-1000)"
    echo -e "    ${YELLOW}--bandwidth${NC}    Bandwidth per peer in Mbps (1-40, or -1 for unlimited)"
    echo ""
    
    # Max clients prompt
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Enter max-clients (1-1000)"
    echo -e "  Press Enter for recommended: ${GREEN}${recommended}${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  max-clients: " input_clients < /dev/tty || true
    
    if [ -z "$input_clients" ]; then
        MAX_CLIENTS=$recommended
    elif [[ "$input_clients" =~ ^[0-9]+$ ]] && [ "$input_clients" -ge 1 ] && [ "$input_clients" -le 1000 ]; then
        MAX_CLIENTS=$input_clients
    else
        log_warn "Invalid input. Using recommended: $recommended"
        MAX_CLIENTS=$recommended
    fi
    
    echo ""
    
    # Bandwidth prompt
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  Do you want to set ${BOLD}UNLIMITED${NC} bandwidth? (Recommended for servers)"
    echo -e "  ${YELLOW}Note: High bandwidth usage may attract attention.${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  Set unlimited bandwidth? [y/N] " unlimited_bw < /dev/tty || true

    if [[ "$unlimited_bw" =~ ^[Yy] ]]; then
        BANDWIDTH="-1"
        echo -e "  Selected: ${GREEN}Unlimited (-1)${NC}"
    else
        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  Enter bandwidth per peer in Mbps (1-40)"
        echo -e "  Press Enter for default: ${GREEN}5${NC} Mbps"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        read -p "  bandwidth: " input_bandwidth < /dev/tty || true
        
        if [ -z "$input_bandwidth" ]; then
            BANDWIDTH=5
        elif [[ "$input_bandwidth" =~ ^[0-9]+$ ]] && [ "$input_bandwidth" -ge 1 ] && [ "$input_bandwidth" -le 40 ]; then
            BANDWIDTH=$input_bandwidth
        elif [[ "$input_bandwidth" =~ ^[0-9]*\.[0-9]+$ ]]; then
            local float_ok=$(awk -v val="$input_bandwidth" 'BEGIN { print (val >= 1 && val <= 40) ? "yes" : "no" }')
            if [ "$float_ok" = "yes" ]; then
                BANDWIDTH=$input_bandwidth
            else
                log_warn "Invalid input. Using default: 5 Mbps"
                BANDWIDTH=5
            fi
        else
            log_warn "Invalid input. Using default: 5 Mbps"
            BANDWIDTH=5
        fi
    fi
    
    echo ""
    
    # Container count prompt (macOS uses alternate ports per container)
    local ram_mb=$(get_ram_mb)
    local cpu_cores=$(get_cpu_cores)
    local ram_gb=$(( ram_mb / 1024 ))
    local rec_cap=32
    local rec_by_cpu=$cpu_cores
    local rec_by_ram=$ram_gb
    [ "$rec_by_ram" -lt 1 ] && rec_by_ram=1
    local rec_containers=$(( rec_by_cpu < rec_by_ram ? rec_by_cpu : rec_by_ram ))
    [ "$rec_containers" -lt 1 ] && rec_containers=1
    [ "$rec_containers" -gt "$rec_cap" ] && rec_containers="$rec_cap"
    
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  How many Conduit containers to run? [1-32]"
    echo -e "  More containers = more connections served"
    if [ "$OS_FAMILY" = "macos" ]; then
        echo -e "  ${YELLOW}Note:${NC} macOS uses per-container ports (443, 444, 445...)"
    fi
    echo ""
    echo -e "  ${DIM}System: ${cpu_cores} CPU core(s), ${ram_mb}MB RAM (~${ram_gb}GB)${NC}"
    if [ "$cpu_cores" -le 1 ] || [ "$ram_mb" -lt 1024 ]; then
        echo -e "  ${YELLOW}⚠ Low-end system detected. Recommended: 1 container.${NC}"
        echo -e "  ${YELLOW}  Multiple containers may cause high CPU and instability.${NC}"
    elif [ "$cpu_cores" -le 2 ]; then
        echo -e "  ${DIM}Recommended: 1-2 containers for this system.${NC}"
    else
        echo -e "  ${DIM}Recommended: up to ${rec_containers} containers for this system.${NC}"
    fi
    echo ""
    echo -e "  Press Enter for default: ${GREEN}${rec_containers}${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    read -p "  containers: " input_containers < /dev/tty || true
    
    if [ -z "$input_containers" ]; then
        CONTAINER_COUNT=$rec_containers
    elif [[ "$input_containers" =~ ^[1-9][0-9]*$ ]]; then
        CONTAINER_COUNT=$input_containers
        if [ "$CONTAINER_COUNT" -gt 32 ]; then
            log_warn "Maximum is 32 containers. Setting to 32."
            CONTAINER_COUNT=32
        elif [ "$CONTAINER_COUNT" -gt "$rec_containers" ]; then
            echo -e "  ${YELLOW}Note:${NC} You chose ${CONTAINER_COUNT}, above recommended ${rec_containers}."
            echo -e "  ${DIM}  This may increase CPU usage or instability.${NC}"
        fi
    else
        log_warn "Invalid input. Using default: ${rec_containers}"
        CONTAINER_COUNT=$rec_containers
    fi
    
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Your Settings:${NC}"
    echo -e "    Max Clients: ${GREEN}${MAX_CLIENTS}${NC}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "    Bandwidth:   ${GREEN}Unlimited${NC}"
    else
        echo -e "    Bandwidth:   ${GREEN}${BANDWIDTH}${NC} Mbps"
    fi
    echo -e "    Containers:  ${GREEN}${CONTAINER_COUNT}${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    read -p "  Proceed with these settings? [Y/n] " confirm < /dev/tty || true
    if [[ "$confirm" =~ ^[Nn] ]]; then
        prompt_settings
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Installation Functions
#═══════════════════════════════════════════════════════════════════════

install_docker() {
    if command -v docker &>/dev/null; then
        log_success "Docker is already installed"
        return 0
    fi
    
    log_info "Installing Docker..."

    # macOS (Apple Silicon): prefer Docker Desktop
    if [ "$OS_FAMILY" = "macos" ]; then
        echo ""
        log_warn "macOS detected. Docker Engine runs via Docker Desktop on macOS."
        echo -e "${YELLOW}Note:${NC} This script supports Apple Silicon (arm64) Macs."
        echo ""

        if ! command -v brew &>/dev/null; then
            log_error "Homebrew not found. Please install Docker Desktop manually."
            log_info "Install Homebrew: https://brew.sh/"
            log_info "Or install Docker Desktop: https://www.docker.com/products/docker-desktop/"
            return 1
        fi

        log_info "Installing Docker Desktop (Homebrew cask)..."
        if brew install --cask docker; then
            log_success "Docker Desktop installed"
            return 0
        else
            log_error "Failed to install Docker Desktop via Homebrew."
            log_info "Please install it manually: https://www.docker.com/products/docker-desktop/"
            return 1
        fi
    fi
    
    # Check OS family for specific requirements
    if [ "$OS_FAMILY" = "rhel" ]; then
        log_info "Installing RHEL-specific Docker dependencies..."
        $PKG_MANAGER install -y -q dnf-plugins-core 2>/dev/null || true
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
    fi

    # Alpine
    if [ "$OS_FAMILY" = "alpine" ]; then
        apk add --no-cache docker docker-cli-compose 2>/dev/null
        rc-update add docker boot 2>/dev/null || true
        service docker start 2>/dev/null || rc-service docker start 2>/dev/null || true
    else
        # Use official Docker install
        if ! curl -fsSL https://get.docker.com | sh; then
            log_error "Official Docker installation script failed."
            log_info "Try installing docker manually: https://docs.docker.com/engine/install/"
            return 1
        fi
        
        # Enable and start Docker
        if [ "$HAS_SYSTEMD" = "true" ]; then
            systemctl enable docker 2>/dev/null || true
            systemctl start docker 2>/dev/null || true
        else
            # Fallback for non-systemd (SysVinit, OpenRC, etc.)
            if command -v update-rc.d &>/dev/null; then
                update-rc.d docker defaults 2>/dev/null || true
            elif command -v chkconfig &>/dev/null; then
                chkconfig docker on 2>/dev/null || true
            elif command -v rc-update &>/dev/null; then
                rc-update add docker default 2>/dev/null || true
            fi
            service docker start 2>/dev/null || /etc/init.d/docker start 2>/dev/null || true
        fi
    fi
    
    # Wait for Docker to be ready
    sleep 3
    local retries=27
    while ! docker info &>/dev/null && [ $retries -gt 0 ]; do
        sleep 1
        retries=$((retries - 1))
    done
    
    if docker info &>/dev/null; then
        log_success "Docker installed successfully"
    else
        log_error "Docker installation may have failed. Please check manually."
        return 1
    fi
}

ensure_docker_running() {
    # Ensures Docker CLI exists AND Docker Engine (daemon) is reachable.
    # If daemon isn't running, prompts user for permission to start it; otherwise exits with an explicit message.

    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed (docker command not found)."
        log_error "Please install Docker and rerun this script."
        exit 1
    fi

    # Fast path: daemon already running
    if docker info &>/dev/null; then
        return 0
    fi

    log_warn "Docker is installed but the Docker Engine (daemon) is not running."
    echo ""
    echo -e "${CYAN}Docker is required to continue.${NC}"
    if [ "$OS_FAMILY" = "macos" ]; then
        echo -e "Docker Desktop needs to be running."
        echo -e "This script can try to open Docker Desktop for you."
    else
        echo -e "This script can try to start the Docker service for you."
    fi
    echo ""
    read -p "Start Docker Engine now? [y/N] " start_docker_confirm < /dev/tty || true

    if [[ ! "$start_docker_confirm" =~ ^[Yy] ]]; then
        echo ""
        log_error "Docker Engine is not running. Cannot continue without Docker."
        log_info "Start it manually, then rerun this script."
        if [ "$OS_FAMILY" = "macos" ]; then
            log_info "  Open Docker Desktop (Applications → Docker)"
        else
            log_info "  systemd:   sudo systemctl start docker"
            log_info "  SysVinit:  sudo service docker start   (or /etc/init.d/docker start)"
            log_info "  OpenRC:    sudo rc-service docker start"
        fi
        exit 1
    fi

    echo ""
    log_info "Starting Docker..."

    if [ "$OS_FAMILY" = "macos" ]; then
        # Docker Desktop (macOS)
        open -a Docker 2>/dev/null || true
    elif [ "$HAS_SYSTEMD" = "true" ]; then
        systemctl start docker 2>/dev/null || true
    else
        # OpenRC / SysVinit fallbacks
        service docker start 2>/dev/null || true
        /etc/init.d/docker start 2>/dev/null || true
        rc-service docker start 2>/dev/null || true
    fi

    # Wait briefly for daemon readiness
    local retries=120
    while ! docker info &>/dev/null && [ $retries -gt 0 ]; do
        sleep 1
        retries=$((retries - 1))
    done

    if docker info &>/dev/null; then
        log_success "Docker Engine is running"
        return 0
    fi

    log_error "Docker Engine is not running (cannot connect to the Docker daemon)."
    log_error "Please start Docker, then rerun this script."
    log_info "Common commands:"
    log_info "  systemd:   sudo systemctl start docker"
    log_info "  SysVinit:  sudo service docker start   (or /etc/init.d/docker start)"
    log_info "  OpenRC:    sudo rc-service docker start"
    exit 1
}


#═══════════════════════════════════════════════════════════════════════
# check_and_offer_backup_restore() - Check for existing backup keys
#═══════════════════════════════════════════════════════════════════════
# Backup location: /opt/conduit/backups/
# Key file format: conduit_key_YYYYMMDD_HHMMSS.json
#
# Returns:
#   0 - Backup was restored (or none existed)
#   1 - User declined restore (fresh install)
#═══════════════════════════════════════════════════════════════════════
check_and_offer_backup_restore() {

    if [ ! -d "$BACKUP_DIR" ]; then
        return 0 
    fi

    # Find the most recent backup file
    local latest_backup=$(ls -t "$BACKUP_DIR"/conduit_key_*.json 2>/dev/null | head -1)

    if [ -z "$latest_backup" ]; then
        return 0 
    fi

    # Extract timestamp from filename for display
    local backup_filename=$(basename "$latest_backup")
    local backup_date=$(echo "$backup_filename" | sed -E 's/conduit_key_([0-9]{8})_([0-9]{6})\.json/\1/')
    local backup_time=$(echo "$backup_filename" | sed -E 's/conduit_key_([0-9]{8})_([0-9]{6})\.json/\2/')

    # Format date for display (YYYYMMDD -> YYYY-MM-DD)
    local formatted_date="${backup_date:0:4}-${backup_date:4:2}-${backup_date:6:2}"
    local formatted_time="${backup_time:0:2}:${backup_time:2:2}:${backup_time:4:2}"

    # Prompt user about restoring the backup
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  📁 PREVIOUS NODE IDENTITY BACKUP FOUND${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  A backup of your node identity key was found:"
    echo -e "    ${YELLOW}File:${NC} $backup_filename"
    echo -e "    ${YELLOW}Date:${NC} $formatted_date $formatted_time"
    echo ""
    echo -e "  Restoring this key will:"
    echo -e "    • Preserve your node's identity on the Psiphon network"
    echo -e "    • Maintain any accumulated reputation"
    echo -e "    • Allow peers to reconnect to your known node ID"
    echo ""
    echo -e "  ${YELLOW}Note:${NC} If you don't restore, a new identity will be generated."
    echo ""

    read -p "  Do you want to restore your previous node identity? (y/n): " restore_choice < /dev/tty || true

    if [ "$restore_choice" = "y" ] || [ "$restore_choice" = "Y" ]; then
        echo ""
        log_info "Restoring node identity from backup..."

        # Ensure the Docker volume exists
        docker volume create conduit-data 2>/dev/null || true
        docker run --rm -v conduit-data:/home/conduit/data -v "$BACKUP_DIR":/backup alpine \
            sh -c "cp /backup/$backup_filename /home/conduit/data/conduit_key.json && chown -R 1000:1000 /home/conduit/data"

        if [ $? -eq 0 ]; then
            log_success "Node identity restored successfully!"
            echo ""
            return 0
        else
            log_error "Failed to restore backup. Proceeding with fresh install."
            echo ""
            return 1
        fi
    else
        echo ""
        log_info "Skipping restore. A new node identity will be generated."
        echo ""
        return 1
    fi
}

# run_conduit() - Pull image, verify digest, and start container
run_conduit() {
    log_info "Starting Conduit container(s)..."
    CONTAINER_COUNT=${CONTAINER_COUNT:-1}
    CONTAINER_PORT_BASE=${CONTAINER_PORT_BASE:-443}

    # Check for existing conduit containers (any image containing conduit)
    local existing=$(docker ps -a --filter "ancestor=ghcr.io/ssmirr/conduit/conduit" --format "{{.Names}}")
    if [ -n "$existing" ] && [ "$existing" != "conduit" ]; then
        log_warn "Detected other Conduit containers: $existing"
        log_warn "Running multiple instances may cause port conflicts."
    fi

    # Stop and remove any existing containers
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local name="conduit"
        [ "$i" -gt 1 ] && name="conduit-${i}"
        docker rm -f "$name" 2>/dev/null || true
    done

    # Pull the official Conduit image from GitHub Container Registry
    log_info "Pulling Conduit image ($CONDUIT_IMAGE)..."
    if ! docker pull $CONDUIT_IMAGE; then
        log_error "Failed to pull Conduit image. Check your internet connection."
        exit 1
    fi


    # Ensure volumes exist and have correct permissions for the conduit user (uid 1000)
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local vol="conduit-data"
        [ "$i" -gt 1 ] && vol="conduit-data-${i}"
        docker volume create "$vol" 2>/dev/null || true
        docker run --rm -v "${vol}:/home/conduit/data" alpine \
            sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true
    done

    # Start Conduit containers
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local name="conduit"
        local vol="conduit-data"
        if [ "$i" -gt 1 ]; then
            name="conduit-${i}"
            vol="conduit-data-${i}"
        fi
        local net_args=""
        if [ "$OS_FAMILY" = "macos" ]; then
            local port=$((CONTAINER_PORT_BASE + i - 1))
            net_args="-p ${port}:443/tcp -p ${port}:443/udp"
            log_warn "macOS detected: publishing ${port}/tcp+udp for ${name}"
        else
            net_args="--network host"
        fi
        docker run -d \
            --name "$name" \
            --restart unless-stopped \
            -v "${vol}:/home/conduit/data" \
            $net_args \
            $CONDUIT_IMAGE \
            start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file "$STATS_FILE"
    done

    # Wait for containers to initialize
    sleep 3

    # Verify containers are running
    local running=0
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local name="conduit"
        [ "$i" -gt 1 ] && name="conduit-${i}"
        if docker ps | grep -q "[[:space:]]${name}$"; then
            running=$((running + 1))
        fi
    done
    if [ "$running" -eq "$CONTAINER_COUNT" ]; then
        log_success "Conduit containers are running (${running}/${CONTAINER_COUNT})"
        if [ "$BANDWIDTH" == "-1" ]; then
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=Unlimited"
        else
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=${BANDWIDTH}Mbps"
        fi
    else
        log_error "Conduit failed to start (${running}/${CONTAINER_COUNT} running)"
        exit 1
    fi
}

save_settings() {
    mkdir -p "$INSTALL_DIR"
    CONTAINER_COUNT=${CONTAINER_COUNT:-1}
    CONTAINER_PORT_BASE=${CONTAINER_PORT_BASE:-443}
    DOCKER_CPUS=${DOCKER_CPUS:-}
    DOCKER_MEMORY=${DOCKER_MEMORY:-}
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
    TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
    TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
    TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
    TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL:-}"
    TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
    TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
    TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
    PERSIST_DIR="$INSTALL_DIR/traffic_stats"
    mkdir -p "$PERSIST_DIR" 2>/dev/null || true
    if [ ! -w "$PERSIST_DIR" ]; then
        PERSIST_DIR="$INSTALL_DIR/traffic_stats-user"
        mkdir -p "$PERSIST_DIR" 2>/dev/null || true
    fi
    if [ ! -w "$PERSIST_DIR" ]; then
        PERSIST_DIR="/tmp/conduit-traffic-${USER:-user}"
        mkdir -p "$PERSIST_DIR" 2>/dev/null || true
    fi
    CONNECTION_HISTORY_FILE="$PERSIST_DIR/connection_history"
    CONNECTION_HISTORY_START_FILE="$PERSIST_DIR/connection_history_start"
    PEAK_CONNECTIONS_FILE="$PERSIST_DIR/peak_connections"
    TRACKER_ENABLED=${TRACKER_ENABLED:-true}
    TRACKER_PID_FILE="$INSTALL_DIR/tracker.pid"
    TRACKER_LOG_FILE="$INSTALL_DIR/tracker.log"
    
    local _tmp="$INSTALL_DIR/settings.conf.tmp.$$"
    cat > "$_tmp" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=$CONTAINER_COUNT
CONTAINER_PORT_BASE=$CONTAINER_PORT_BASE
DOCKER_CPUS=${DOCKER_CPUS:-}
DOCKER_MEMORY=${DOCKER_MEMORY:-}
TRACKER_ENABLED=${TRACKER_ENABLED:-true}
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL:-}"
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
EOF
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local mc_var="MAX_CLIENTS_${i}"
        local bw_var="BANDWIDTH_${i}"
        local cpu_var="CPUS_${i}"
        local mem_var="MEMORY_${i}"
        [ -n "${!mc_var}" ] && echo "${mc_var}=${!mc_var}" >> "$_tmp"
        [ -n "${!bw_var}" ] && echo "${bw_var}=${!bw_var}" >> "$_tmp"
        [ -n "${!cpu_var}" ] && echo "${cpu_var}=${!cpu_var}" >> "$_tmp"
        [ -n "${!mem_var}" ] && echo "${mem_var}=${!mem_var}" >> "$_tmp"
    done
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$INSTALL_DIR/settings.conf"
    
    if [ ! -f "$INSTALL_DIR/settings.conf" ]; then
        log_error "Failed to save settings. Check disk space and permissions."
        return 1
    fi
    
    log_success "Settings saved"
}

setup_autostart() {
    log_info "Setting up auto-start on boot..."

    if [ "$OS_FAMILY" = "macos" ]; then
        log_warn "Auto-start is not configured on macOS by this script (launchd support not yet implemented)."
        log_info "Tip: Configure Docker Desktop to start at login, then run: conduit start"
        return 0
    fi
    
    if [ "$HAS_SYSTEMD" = "true" ]; then
        # Systemd-based systems
        local docker_path=$(command -v docker)
        cat > /etc/systemd/system/conduit.service << EOF
[Unit]
Description=Psiphon Conduit Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$docker_path start conduit
ExecStop=$docker_path stop conduit

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable conduit.service 2>/dev/null || true
        systemctl start conduit.service 2>/dev/null || true
        log_success "Systemd service created, enabled, and started"
        
    elif command -v rc-update &>/dev/null; then
        # OpenRC (Alpine, Gentoo, etc.)
        cat > /etc/init.d/conduit << 'EOF'
#!/sbin/openrc-run

name="conduit"
description="Psiphon Conduit Service"
depend() {
    need docker
    after network
}
start() {
    ebegin "Starting Conduit"
    docker start conduit
    eend $?
}
stop() {
    ebegin "Stopping Conduit"
    docker stop conduit
    eend $?
}
EOF
        chmod +x /etc/init.d/conduit
        rc-update add conduit default 2>/dev/null || true
        log_success "OpenRC service created and enabled"
        
    elif [ -d /etc/init.d ]; then
        # SysVinit fallback
        cat > /etc/init.d/conduit << 'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          conduit
# Required-Start:    $docker
# Required-Stop:     $docker
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Psiphon Conduit Service
### END INIT INFO

case "$1" in
    start)
        docker start conduit
        ;;
    stop)
        docker stop conduit
        ;;
    restart)
        docker restart conduit
        ;;
    status)
        docker ps | grep -q conduit && echo "Running" || echo "Stopped"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
EOF
        chmod +x /etc/init.d/conduit
        if command -v update-rc.d &>/dev/null; then
            update-rc.d conduit defaults 2>/dev/null || true
        elif command -v chkconfig &>/dev/null; then
            chkconfig conduit on 2>/dev/null || true
        fi
        log_success "SysVinit service created and enabled"
        
    else
        log_warn "Could not set up auto-start. Docker's restart policy will handle restarts."
        log_info "Container is set to restart unless-stopped, which works on reboot if Docker starts."
    fi
}

# Load settings after INSTALL_DIR is finalized
load_settings() {
    local settings_path="$INSTALL_DIR/settings.conf"
    local had_settings=false
    local has_container_count=false
    if [ -f "$settings_path" ]; then
        had_settings=true
        if grep -q '^CONTAINER_COUNT=' "$settings_path" 2>/dev/null; then
            has_container_count=true
        fi
        source "$settings_path"
    fi
    MAX_CLIENTS=${MAX_CLIENTS:-200}
    BANDWIDTH=${BANDWIDTH:-5}
    CONTAINER_COUNT=${CONTAINER_COUNT:-1}
    CONTAINER_PORT_BASE=${CONTAINER_PORT_BASE:-443}
    DOCKER_CPUS=${DOCKER_CPUS:-}
    DOCKER_MEMORY=${DOCKER_MEMORY:-}
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
    TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
    TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
    TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL:-}"
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
    TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
    PERSIST_DIR="$INSTALL_DIR/traffic_stats"
    mkdir -p "$PERSIST_DIR" 2>/dev/null || true
    if [ ! -w "$PERSIST_DIR" ]; then
        PERSIST_DIR="$INSTALL_DIR/traffic_stats-user"
        mkdir -p "$PERSIST_DIR" 2>/dev/null || true
    fi
    if [ ! -w "$PERSIST_DIR" ]; then
        PERSIST_DIR="/tmp/conduit-traffic-${USER:-user}"
        mkdir -p "$PERSIST_DIR" 2>/dev/null || true
    fi
    CONNECTION_HISTORY_FILE="$PERSIST_DIR/connection_history"
    CONNECTION_HISTORY_START_FILE="$PERSIST_DIR/connection_history_start"
    PEAK_CONNECTIONS_FILE="$PERSIST_DIR/peak_connections"

    if [ "$has_container_count" = false ]; then
        local detected=0
        if command -v docker &>/dev/null; then
            local names
            names=$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
            for n in $names; do
                if [ "$n" = "conduit" ]; then
                    [ "$detected" -lt 1 ] && detected=1
                elif [[ "$n" =~ ^conduit-([0-9]+)$ ]]; then
                    local idx="${BASH_REMATCH[1]}"
                    [ "$idx" -gt "$detected" ] && detected="$idx"
                fi
            done
        fi
        if [ "$detected" -gt 0 ] 2>/dev/null; then
            CONTAINER_COUNT="$detected"
            if [ "$had_settings" = true ]; then
                save_settings
            fi
        fi
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Management Script
#═══════════════════════════════════════════════════════════════════════

create_management_script() {
    # Generate the management script. 
    cat > "$INSTALL_DIR/conduit" << 'MANAGEMENT'
#!/bin/bash
#
# Psiphon Conduit Manager
# Reference: https://github.com/ssmirr/conduit/releases/tag/d8522a8
#

VERSION="1.1.0-Mac"
INSTALL_DIR="REPLACE_ME_INSTALL_DIR"
BACKUP_DIR="$INSTALL_DIR/backups"
GEOIP_DIR="$INSTALL_DIR/geoip"
GEOIP_MMDB="$GEOIP_DIR/dbip-country-lite.mmdb"
STATS_FILE="/home/conduit/data/conduit_stats.json"
CONDUIT_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
PERSIST_DIR="$INSTALL_DIR/traffic_stats"
CONNECTION_HISTORY_FILE="$PERSIST_DIR/connection_history"
CONNECTION_HISTORY_START_FILE="$PERSIST_DIR/connection_history_start"
PEAK_CONNECTIONS_FILE="$PERSIST_DIR/peak_connections"
TRACKER_PID_FILE="$INSTALL_DIR/tracker.pid"
TRACKER_LOG_FILE="$INSTALL_DIR/tracker.log"

# On macOS, prefer Homebrew bash (supports associative arrays). Re-exec if needed.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    if command -v /opt/homebrew/bin/bash >/dev/null 2>&1; then
        if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
            exec /opt/homebrew/bin/bash "$0" "$@"
        fi
    elif command -v /usr/local/bin/bash >/dev/null 2>&1; then
        if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
            exec /usr/local/bin/bash "$0" "$@"
        fi
    fi
    # If still on old bash (<4), warn; associative arrays may fail
    if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        echo "Warning: macOS system bash is too old (<4). Install Homebrew bash: brew install bash"
    fi
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# OS family (used for platform-specific behavior)
OS_FAMILY="unknown"
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    OS_FAMILY="macos"
else
    OS_FAMILY="linux"
fi

# Ensure we have bash 4+ (macOS system bash is 3.x)
ensure_bash_v4() {
    if [ -n "${BASH_VERSINFO[0]:-}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
        return 0
    fi

    local brew_prefix=""
    command -v brew &>/dev/null && brew_prefix="$(brew --prefix 2>/dev/null || true)"
    local brew_bash="${brew_prefix:+$brew_prefix/bin/bash}"
    [ -z "$brew_bash" ] && brew_bash="/opt/homebrew/bin/bash"

    if [ -x "$brew_bash" ]; then
        echo "Re-executing with newer bash: $brew_bash"
        exec "$brew_bash" "$0" "$@"
    fi

    echo -e "${RED}Error: This script requires bash 4 or newer.${NC}"
    echo "macOS system bash is too old (3.x). Install a newer bash:"
    echo "  brew install bash"
    echo "Then rerun: $0"
    exit 1
}

ensure_bash_v4 "$@"

load_settings() {
    local settings_path="$INSTALL_DIR/settings.conf"
    local had_settings=false
    local has_container_count=false
    if [ -f "$settings_path" ]; then
        had_settings=true
        if grep -q '^CONTAINER_COUNT=' "$settings_path" 2>/dev/null; then
            has_container_count=true
        fi
        source "$settings_path"
    fi
    MAX_CLIENTS=${MAX_CLIENTS:-200}
    BANDWIDTH=${BANDWIDTH:-5}
    CONTAINER_COUNT=${CONTAINER_COUNT:-1}
    CONTAINER_PORT_BASE=${CONTAINER_PORT_BASE:-443}
    DOCKER_CPUS=${DOCKER_CPUS:-}
    DOCKER_MEMORY=${DOCKER_MEMORY:-}
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
    TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
    TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
    TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
    TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL:-}"
    TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
    TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
    TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}

    if [ "$has_container_count" = false ]; then
        local detected=0
        if command -v docker &>/dev/null; then
            local names
            names=$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
            for n in $names; do
                if [ "$n" = "conduit" ]; then
                    [ "$detected" -lt 1 ] && detected=1
                elif [[ "$n" =~ ^conduit-([0-9]+)$ ]]; then
                    local idx="${BASH_REMATCH[1]}"
                    [ "$idx" -gt "$detected" ] && detected="$idx"
                fi
            done
        fi
        if [ "$detected" -gt 0 ] 2>/dev/null; then
            CONTAINER_COUNT="$detected"
            if [ "$had_settings" = true ]; then
                save_settings
            fi
        fi
    fi
}

save_settings() {
    mkdir -p "$INSTALL_DIR"
    CONTAINER_COUNT=${CONTAINER_COUNT:-1}
    CONTAINER_PORT_BASE=${CONTAINER_PORT_BASE:-443}
    DOCKER_CPUS=${DOCKER_CPUS:-}
    DOCKER_MEMORY=${DOCKER_MEMORY:-}
    PERSIST_DIR="$INSTALL_DIR/traffic_stats"
    mkdir -p "$PERSIST_DIR" 2>/dev/null || true
    if [ ! -w "$PERSIST_DIR" ]; then
        PERSIST_DIR="$INSTALL_DIR/traffic_stats-user"
        mkdir -p "$PERSIST_DIR" 2>/dev/null || true
    fi
    if [ ! -w "$PERSIST_DIR" ]; then
        PERSIST_DIR="/tmp/conduit-traffic-${USER:-user}"
        mkdir -p "$PERSIST_DIR" 2>/dev/null || true
    fi
    CONNECTION_HISTORY_FILE="$PERSIST_DIR/connection_history"
    CONNECTION_HISTORY_START_FILE="$PERSIST_DIR/connection_history_start"
    PEAK_CONNECTIONS_FILE="$PERSIST_DIR/peak_connections"
    TRACKER_ENABLED=${TRACKER_ENABLED:-true}
    TRACKER_PID_FILE="$INSTALL_DIR/tracker.pid"
    TRACKER_LOG_FILE="$INSTALL_DIR/tracker.log"
    TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
    TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
    if [ "$OS_FAMILY" = "macos" ]; then
        TELEGRAM_ALERT_PEERS=${TELEGRAM_ALERT_PEERS:-false}
    else
        TELEGRAM_ALERT_PEERS=${TELEGRAM_ALERT_PEERS:-true}
    fi
    TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
    TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}

    local _tmp="$INSTALL_DIR/settings.conf.tmp.$$"
    cat > "$_tmp" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=$CONTAINER_COUNT
CONTAINER_PORT_BASE=$CONTAINER_PORT_BASE
DOCKER_CPUS=${DOCKER_CPUS:-}
DOCKER_MEMORY=${DOCKER_MEMORY:-}
TRACKER_ENABLED=${TRACKER_ENABLED:-true}
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL:-}"
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
EOF
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local mc_var="MAX_CLIENTS_${i}"
        local bw_var="BANDWIDTH_${i}"
        local cpu_var="CPUS_${i}"
        local mem_var="MEMORY_${i}"
        [ -n "${!mc_var}" ] && echo "${mc_var}=${!mc_var}" >> "$_tmp"
        [ -n "${!bw_var}" ] && echo "${bw_var}=${!bw_var}" >> "$_tmp"
        [ -n "${!cpu_var}" ] && echo "${cpu_var}=${!cpu_var}" >> "$_tmp"
        [ -n "${!mem_var}" ] && echo "${mem_var}=${!mem_var}" >> "$_tmp"
    done
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$INSTALL_DIR/settings.conf"

    if [ ! -f "$INSTALL_DIR/settings.conf" ]; then
        echo -e "${RED}Failed to save settings. Check disk space and permissions.${NC}"
        return 1
    fi
}

# On macOS, Docker works without root. Some features (like tcpdump) may still require sudo.
if [ "$(uname -s 2>/dev/null)" != "Darwin" ]; then
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: This command must be run as root (use sudo conduit)${NC}"
        exit 1
    fi
fi

# Check if Docker is available
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Error: Docker is not installed!${NC}"
        echo ""
        echo "Docker is required to run Conduit. Please reinstall:"
        echo "  curl -fsSL https://get.docker.com | sudo sh"
        echo ""
        echo "Or re-run the Conduit installer:"
        echo "  sudo bash conduit.sh"
        exit 1
    fi
    
    if ! docker info &>/dev/null; then
        echo -e "${RED}Error: Docker daemon is not running!${NC}"
        echo ""
        echo "Start Docker with:"
        echo "  sudo systemctl start docker       # For systemd"
        echo "  sudo /etc/init.d/docker start     # For SysVinit"
        echo "  sudo rc-service docker start      # For OpenRC"
        exit 1
    fi
}

# Run Docker check
check_docker

# Check for awk (needed for stats parsing)
if ! command -v awk &>/dev/null; then
    echo -e "${YELLOW}Warning: awk not found. Some stats may not display correctly.${NC}"
fi

# GeoIP helpers (macOS uses mmdblookup + DB-IP Lite database)
resolve_geoip_db() {
    local path="$GEOIP_MMDB"
    if [ -f "$path" ]; then
        echo "$path"
        return
    fi

    # If running under sudo on macOS, also check the invoking user's install dir
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && [ -n "${SUDO_USER:-}" ]; then
        local user_home=""
        user_home=$(eval echo "~${SUDO_USER}" 2>/dev/null || true)
        if [ -n "$user_home" ]; then
            local alt1="$user_home/.conduit/geoip/dbip-country-lite.mmdb"
            local alt2="$user_home/.conduit-user/geoip/dbip-country-lite.mmdb"
            [ -f "$alt1" ] && { echo "$alt1"; return; }
            [ -f "$alt2" ] && { echo "$alt2"; return; }
        fi
    fi

    echo ""
}

find_mmdblookup() {
    # Try PATH first
    if command -v mmdblookup >/dev/null 2>&1; then
        command -v mmdblookup
        return
    fi
    # Common Homebrew locations (sudo may not inherit PATH)
    if [ -x "/opt/homebrew/bin/mmdblookup" ]; then
        echo "/opt/homebrew/bin/mmdblookup"
        return
    fi
    if [ -x "/usr/local/bin/mmdblookup" ]; then
        echo "/usr/local/bin/mmdblookup"
        return
    fi
    echo ""
}

geoip_lookup_country() {
    local ip="$1"
    if [ -z "$ip" ]; then
        echo "Unknown"
        return
    fi

    if command -v geoiplookup &>/dev/null; then
        # Linux: geoiplookup output example: "GeoIP Country Edition: US, United States"
        geoiplookup "$ip" 2>/dev/null | awk -F: '/Country Edition/{print $2}' | sed 's/^ //'
        return
    fi

    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        local mmdb_bin
        mmdb_bin="$(find_mmdblookup)"
        if [ -z "$mmdb_bin" ]; then
            echo "Unknown"
            return
        fi
        local mmdb_path
        mmdb_path="$(resolve_geoip_db)"
        if [ -z "$mmdb_path" ] || [ ! -f "$mmdb_path" ]; then
            echo "Unknown"
            return
        fi
        # Extract country (prefer English name; fallback to ISO code).
        # mmdblookup output format varies; use grep-based parsing for robustness.
        local name_line name
        name_line=$("$mmdb_bin" --file "$mmdb_path" --ip "$ip" country names en 2>/dev/null | tr -d '\r')
        name=$(echo "$name_line" | grep -Eo '"[^"]+"' | tail -1 | tr -d '"')
        if [ -n "$name" ]; then
            echo "$name"
            return
        fi

        local iso_line iso
        iso_line=$("$mmdb_bin" --file "$mmdb_path" --ip "$ip" country iso_code 2>/dev/null | tr -d '\r')
        iso=$(echo "$iso_line" | grep -Eo '"[A-Z]{2}"' | head -1 | tr -d '"')
        if [ -n "$iso" ]; then
            echo "$iso"
            return
        fi
        echo "Unknown"
        return
    fi

    echo "Unknown"
}

geoip_diag() {
    # Lightweight diagnostic to help troubleshoot "Unknown" countries on macOS.
    local mmdb_bin mmdb_path sample result
    mmdb_bin="$(find_mmdblookup)"
    mmdb_path="$(resolve_geoip_db)"

    echo "GeoIP diagnostic (DB-IP Lite):"
    echo "  mmdblookup: ${mmdb_bin:-not found}"
    echo "  mmdb path : ${mmdb_path:-not found}"

    sample="8.8.8.8"
    if [ -n "$mmdb_bin" ] && [ -n "$mmdb_path" ] && [ -f "$mmdb_path" ]; then
        result=$("$mmdb_bin" --file "$mmdb_path" --ip "$sample" country names en 2>/dev/null | awk -F'"' '/"en"/{print $4; exit}')
        if [ -z "$result" ]; then
            result=$("$mmdb_bin" --file "$mmdb_path" --ip "$sample" country iso_code 2>/dev/null | awk -F'"' '/\"iso_code\"/{getline; if ($0 ~ /\"[A-Z]{2}\"/) {gsub(/"/,""); print $1; exit}}')
        fi
        echo "  sample ${sample}: ${result:-Unknown}"
    else
        echo "  sample lookup: unavailable"
    fi
    echo ""
}

update_geoip_db() {
    if [ "$(uname -s 2>/dev/null)" != "Darwin" ]; then
        echo -e "${YELLOW}GeoIP DB updater is only needed on macOS.${NC}"
        return 0
    fi

    mkdir -p "$GEOIP_DIR"

    if [ -f "$GEOIP_MMDB" ]; then
        read -p "Replace existing GeoIP database? [y/N] " confirm < /dev/tty || true
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            echo "Cancelled."
            return 0
        fi
    fi

    echo -e "${CYAN}Downloading DB-IP Lite database...${NC}"
    local tmpdir
    tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t conduit_geoip)"
    local download_path="$tmpdir/dbip-country-lite.mmdb.gz"
    local download_ok=0
    local year_month=""
    local url=""

    year_month="$(date +%Y-%m 2>/dev/null || echo "")"
    if [ -n "$year_month" ]; then
        url="https://download.db-ip.com/free/dbip-country-lite-${year_month}.mmdb.gz"
        if curl -fL -sS "$url" -o "$download_path"; then
            download_ok=1
        fi
    fi

    if [ "$download_ok" -ne 1 ]; then
        local prev_year_month=""
        if date -v -1m +%Y-%m >/dev/null 2>&1; then
            prev_year_month="$(date -v -1m +%Y-%m 2>/dev/null || echo "")"
        elif date -d "1 month ago" +%Y-%m >/dev/null 2>&1; then
            prev_year_month="$(date -d "1 month ago" +%Y-%m 2>/dev/null || echo "")"
        fi
        if [ -n "$prev_year_month" ]; then
            url="https://download.db-ip.com/free/dbip-country-lite-${prev_year_month}.mmdb.gz"
            if curl -fL -sS "$url" -o "$download_path"; then
                download_ok=1
            fi
        fi
    fi

    if [ "$download_ok" -ne 1 ]; then
        echo -e "${RED}Failed to download DB-IP Lite database.${NC}"
        rm -rf "$tmpdir" 2>/dev/null || true
        return 1
    fi

    local extracted_mmdb="$tmpdir/dbip-country-lite.mmdb"
    local file_type=""
    if command -v file &>/dev/null; then
        file_type="$(file -b "$download_path" 2>/dev/null || true)"
    fi

    if [ -z "$file_type" ] && command -v od &>/dev/null; then
        local magic
        magic="$(od -An -t x1 -N 4 "$download_path" 2>/dev/null | tr -d ' \n')"
        case "$magic" in
            504b0304) file_type="zip" ;;
            1f8b08*) file_type="gzip" ;;
            3c21444f|3c68746d) file_type="html" ;;
        esac
    fi

    case "$file_type" in
        *HTML*|*html*)
            echo -e "${RED}Download did not return a database file (HTML response).${NC}"
            rm -rf "$tmpdir" 2>/dev/null || true
            return 1
            ;;
        *gzip*|*GZIP*|*gz*)
            if ! command -v gzip &>/dev/null; then
                echo -e "${RED}Gzip archive detected but gzip is not available.${NC}"
                rm -rf "$tmpdir" 2>/dev/null || true
                return 1
            fi
            if ! gzip -dc "$download_path" > "$extracted_mmdb" 2>/dev/null; then
                echo -e "${RED}Failed to extract DB-IP Lite gzip archive.${NC}"
                rm -rf "$tmpdir" 2>/dev/null || true
                return 1
            fi
            ;;
        *Zip*|*zip*)
            if command -v unzip &>/dev/null; then
                if ! unzip -p "$download_path" "*.mmdb" > "$extracted_mmdb" 2>/dev/null; then
                    echo -e "${RED}Failed to extract DB-IP Lite zip archive.${NC}"
                    rm -rf "$tmpdir" 2>/dev/null || true
                    return 1
                fi
            elif command -v python3 &>/dev/null; then
                if ! python3 - "$download_path" "$extracted_mmdb" <<'PY'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    for name in z.namelist():
        if name.lower().endswith(".mmdb"):
            with z.open(name) as f, open(dst, "wb") as out:
                out.write(f.read())
            sys.exit(0)
sys.exit(1)
PY
                then
                    echo -e "${RED}Failed to extract DB-IP Lite zip archive.${NC}"
                    rm -rf "$tmpdir" 2>/dev/null || true
                    return 1
                fi
            else
                echo -e "${RED}Zip archive detected but unzip/python3 not available.${NC}"
                rm -rf "$tmpdir" 2>/dev/null || true
                return 1
            fi
            ;;
        *)
            # Assume direct MMDB download
            cp "$download_path" "$extracted_mmdb" 2>/dev/null || true
            ;;
    esac

    if [ ! -f "$extracted_mmdb" ]; then
        echo -e "${RED}DB-IP Lite MMDB not found in downloaded archive.${NC}"
        rm -rf "$tmpdir" 2>/dev/null || true
        return 1
    fi

    if ! cp "$extracted_mmdb" "$GEOIP_MMDB"; then
        echo -e "${RED}Failed to install GeoIP database to: $GEOIP_MMDB${NC}"
        rm -rf "$tmpdir" 2>/dev/null || true
        return 1
    fi

    rm -rf "$tmpdir" 2>/dev/null || true
    echo -e "${GREEN}✓ GeoIP database updated: $GEOIP_MMDB${NC}"
}

run_with_timeout() {
    # Usage: run_with_timeout <seconds> <command...>
    local seconds="$1"
    shift
    if command -v timeout &>/dev/null; then
        timeout "$seconds" "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$seconds" "$@"
    elif command -v perl &>/dev/null; then
        # Portable fallback using perl alarm
        perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
    elif command -v python3 &>/dev/null; then
        # Python fallback if perl is unavailable (macOS may not ship perl)
        python3 -c 'import signal, subprocess, sys
def handler(signum, frame):
    raise TimeoutError()
signal.signal(signal.SIGALRM, handler)
sec = int(sys.argv[1])
cmd = sys.argv[2:]
if not cmd:
    sys.exit(0)
signal.alarm(sec)
try:
    result = subprocess.run(cmd)
    signal.alarm(0)
    sys.exit(result.returncode)
except TimeoutError:
    sys.exit(124)
' "$seconds" "$@"
    else
        echo "Error: timeout requires 'timeout', 'gtimeout', 'perl', or 'python3'." >&2
        return 124
    fi
}

# Helper: Get container name by index (1-based)
get_container_name() {
    local idx=${1:-1}
    if [ "$idx" -eq 1 ]; then
        echo "conduit"
    else
        echo "conduit-${idx}"
    fi
}

# Helper: Get volume name by index (1-based)
get_volume_name() {
    local idx=${1:-1}
    if [ "$idx" -eq 1 ]; then
        echo "conduit-data"
    else
        echo "conduit-data-${idx}"
    fi
}

# Helper: Get host port by index (macOS uses per-container ports)
get_container_port() {
    local idx=${1:-1}
    if [ "$OS_FAMILY" = "macos" ]; then
        echo $((CONTAINER_PORT_BASE + idx - 1))
    else
        echo 443
    fi
}

get_container_max_clients() {
    local idx=${1:-1}
    local var="MAX_CLIENTS_${idx}"
    local val="${!var}"
    echo "${val:-$MAX_CLIENTS}"
}

get_container_bandwidth() {
    local idx=${1:-1}
    local var="BANDWIDTH_${idx}"
    local val="${!var}"
    echo "${val:-$BANDWIDTH}"
}

get_container_cpus() {
    local idx=${1:-1}
    local var="CPUS_${idx}"
    local val="${!var}"
    echo "${val:-${DOCKER_CPUS:-}}"
}

get_container_memory() {
    local idx=${1:-1}
    local var="MEMORY_${idx}"
    local val="${!var}"
    echo "${val:-${DOCKER_MEMORY:-}}"
}

sync_settings_from_containers() {
    local should_save="${1:-true}"  # Allow caller to control whether to save
    if ! command -v docker &>/dev/null; then
        return 0
    fi
    local names
    names=$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
    local detected=0
    for n in $names; do
        if [ "$n" = "conduit" ]; then
            [ "$detected" -lt 1 ] && detected=1
        elif [[ "$n" =~ ^conduit-([0-9]+)$ ]]; then
            local idx="${BASH_REMATCH[1]}"
            [ "$idx" -gt "$detected" ] && detected="$idx"
        fi
    done
    [ "$detected" -lt 1 ] && return 0

    local old_count="$CONTAINER_COUNT"
    CONTAINER_COUNT="$detected"
    local settings_changed=false
    
    # Track if container count changed
    [ "$old_count" != "$CONTAINER_COUNT" ] && settings_changed=true

    local mc_default=""
    local bw_default=""
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local cname=$(get_container_name "$i")
        local args
        args=$(docker inspect --format '{{join .Args " "}}' "$cname" 2>/dev/null || true)
        [ -z "$args" ] && continue
        local mc
        local bw
        mc=$(echo "$args" | sed -n 's/.*--max-clients \([^ ]*\).*/\1/p')
        bw=$(echo "$args" | sed -n 's/.*--bandwidth \([^ ]*\).*/\1/p')
        [ -z "$mc" ] && mc="$MAX_CLIENTS"
        [ -z "$bw" ] && bw="$BANDWIDTH"

        if [ "$i" -eq 1 ]; then
            mc_default="$mc"
            bw_default="$bw"
            [ "$MAX_CLIENTS" != "$mc" ] && settings_changed=true
            [ "$BANDWIDTH" != "$bw" ] && settings_changed=true
            MAX_CLIENTS="$mc"
            BANDWIDTH="$bw"
        else
            local old_mc="${!MAX_CLIENTS_${i}}"
            local old_bw="${!BANDWIDTH_${i}}"
            if [ "$mc" != "$mc_default" ]; then
                [ "$old_mc" != "$mc" ] && settings_changed=true
                printf -v "MAX_CLIENTS_${i}" "%s" "$mc"
            else
                [ -n "$old_mc" ] && settings_changed=true
                unset "MAX_CLIENTS_${i}" 2>/dev/null || true
            fi
            if [ "$bw" != "$bw_default" ]; then
                [ "$old_bw" != "$bw" ] && settings_changed=true
                printf -v "BANDWIDTH_${i}" "%s" "$bw"
            else
                [ -n "$old_bw" ] && settings_changed=true
                unset "BANDWIDTH_${i}" 2>/dev/null || true
            fi
        fi
    done

    # Only save if settings changed and caller wants to save
    if [ "$should_save" = "true" ] && [ "$settings_changed" = "true" ]; then
        if command -v save_settings >/dev/null 2>&1; then
            save_settings
        else
            local settings_path="$INSTALL_DIR/settings.conf"
            local tmp="${settings_path}.tmp.$$"
            cat > "$tmp" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=$CONTAINER_COUNT
CONTAINER_PORT_BASE=$CONTAINER_PORT_BASE
DOCKER_CPUS=${DOCKER_CPUS:-}
DOCKER_MEMORY=${DOCKER_MEMORY:-}
TRACKER_ENABLED=${TRACKER_ENABLED:-true}
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL:-}"
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
EOF
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            local mc_var="MAX_CLIENTS_${i}"
            local bw_var="BANDWIDTH_${i}"
            [ -n "${!mc_var}" ] && echo "${mc_var}=${!mc_var}" >> "$tmp"
            [ -n "${!bw_var}" ] && echo "${bw_var}=${!bw_var}" >> "$tmp"
        done
        mv "$tmp" "$settings_path"
        fi
    fi
}

is_tracker_active() {
    if [ -f "$TRACKER_PID_FILE" ]; then
        local pid
        pid=$(cat "$TRACKER_PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

stop_tracker_service() {
    if [ -f "$TRACKER_PID_FILE" ]; then
        local pid
        pid=$(cat "$TRACKER_PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$TRACKER_PID_FILE" 2>/dev/null || true
    fi
}

regenerate_tracker_script() {
    cat > "$INSTALL_DIR/conduit-tracker.sh" << 'EOF'
#!/opt/homebrew/bin/bash
INSTALL_DIR="${INSTALL_DIR:-$HOME/.conduit}"

# Load settings
if [ -f "$INSTALL_DIR/settings.conf" ]; then
    source "$INSTALL_DIR/settings.conf"
fi

CONTAINER_COUNT="${CONTAINER_COUNT:-1}"
PERSIST_DIR="${PERSIST_DIR:-$INSTALL_DIR/traffic_stats}"
CONNECTION_HISTORY_FILE="${CONNECTION_HISTORY_FILE:-$PERSIST_DIR/connection_history}"
CONNECTION_HISTORY_START_FILE="${CONNECTION_HISTORY_START_FILE:-$PERSIST_DIR/connection_history_start}"
PEAK_CONNECTIONS_FILE="${PEAK_CONNECTIONS_FILE:-$PERSIST_DIR/peak_connections}"
_LAST_HISTORY_RECORD=0
_PEAK_CONNECTIONS=0
_PEAK_CONTAINER_START=""
_AVG_CONN_CACHE=""
_AVG_CONN_CACHE_TIME=0

# Helper function to fix file ownership when running as root
fix_file_ownership() {
    local file="$1"
    [ ! -e "$file" ] && return 0
    if [ "$EUID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
        chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$file" 2>/dev/null || true
    fi
}

# Docker binary detection
DOCKER_BIN=""
for candidate in docker podman; do
    if command -v "$candidate" >/dev/null 2>&1; then
        DOCKER_BIN="$candidate"
        break
    fi
done
[ -z "$DOCKER_BIN" ] && exit 1

get_container_name() {
    local idx=${1:-1}
    if [ "$idx" -eq 1 ]; then
        echo "conduit"
    else
        echo "conduit-${idx}"
    fi
}

get_container_start_time() {
    local earliest=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i 2>/dev/null)
        [ -z "$cname" ] && continue
        local start=$($DOCKER_BIN inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
        [ -z "$start" ] && continue
        if [ -z "$earliest" ] || [[ "$start" < "$earliest" ]]; then
            earliest="$start"
        fi
    done
    echo "$earliest"
}

load_peak_connections() {
    local current_start=$(get_container_start_time)
    if [ -f "$PEAK_CONNECTIONS_FILE" ]; then
        local saved_start=$(head -1 "$PEAK_CONNECTIONS_FILE" 2>/dev/null)
        local saved_peak=$(tail -1 "$PEAK_CONNECTIONS_FILE" 2>/dev/null)
        if [ "$saved_start" = "$current_start" ] && [ -n "$saved_peak" ]; then
            _PEAK_CONNECTIONS=$saved_peak
            _PEAK_CONTAINER_START="$current_start"
            return
        fi
    fi
    _PEAK_CONNECTIONS=0
    _PEAK_CONTAINER_START="$current_start"
    save_peak_connections
}

save_peak_connections() {
    mkdir -p "$(dirname "$PEAK_CONNECTIONS_FILE")" 2>/dev/null
    echo "$_PEAK_CONTAINER_START" > "$PEAK_CONNECTIONS_FILE"
    echo "$_PEAK_CONNECTIONS" >> "$PEAK_CONNECTIONS_FILE"
    fix_file_ownership "$PEAK_CONNECTIONS_FILE"
}

check_connection_history_reset() {
    local current_start=$(get_container_start_time)
    if [ -f "$CONNECTION_HISTORY_START_FILE" ]; then
        local saved_start=$(cat "$CONNECTION_HISTORY_START_FILE" 2>/dev/null)
        if [ "$saved_start" = "$current_start" ] && [ -n "$saved_start" ]; then
            return
        fi
    fi
    mkdir -p "$(dirname "$CONNECTION_HISTORY_START_FILE")" 2>/dev/null
    echo "$current_start" > "$CONNECTION_HISTORY_START_FILE"
    fix_file_ownership "$CONNECTION_HISTORY_START_FILE"
    rm -f "$CONNECTION_HISTORY_FILE" 2>/dev/null
    _AVG_CONN_CACHE=""
    _AVG_CONN_CACHE_TIME=0
}

record_connection_history() {
    local connected=$1
    local connecting=$2
    local now=$(date +%s)
    if [ $(( now - _LAST_HISTORY_RECORD )) -lt 300 ]; then
        return
    fi
    _LAST_HISTORY_RECORD=$now
    check_connection_history_reset
    mkdir -p "$(dirname "$CONNECTION_HISTORY_FILE")" 2>/dev/null
    echo "${now}|${connected}|${connecting}" >> "$CONNECTION_HISTORY_FILE"
    fix_file_ownership "$CONNECTION_HISTORY_FILE"
    local cutoff=$((now - 90000))
    if [ -f "$CONNECTION_HISTORY_FILE" ]; then
        awk -F'|' -v cutoff="$cutoff" '$1 >= cutoff' "$CONNECTION_HISTORY_FILE" > "${CONNECTION_HISTORY_FILE}.tmp" 2>/dev/null
        mv -f "${CONNECTION_HISTORY_FILE}.tmp" "$CONNECTION_HISTORY_FILE" 2>/dev/null
        fix_file_ownership "$CONNECTION_HISTORY_FILE"
    fi
}

get_totals() {
    local total_connected=0
    local total_connecting=0
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local cname=$(get_container_name "$i")
        local logs=$($DOCKER_BIN logs --tail 200 "$cname" 2>/dev/null | grep "\[STATS\]" | tail -1)
        [ -z "$logs" ] && continue
        local cing=$(echo "$logs" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p')
        local conn=$(echo "$logs" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
        cing=${cing:-0}
        conn=${conn:-0}
        total_connecting=$((total_connecting + cing))
        total_connected=$((total_connected + conn))
    done
    echo "${total_connected}|${total_connecting}"
}

# Helper function to convert hex IP to decimal format (little-endian)
hex_to_ip() {
    local hex="$1"
    printf "%d.%d.%d.%d" \
        0x${hex:6:2} 0x${hex:4:2} 0x${hex:2:2} 0x${hex:0:2}
}

# Traffic tracking using Docker /proc/net/tcp inspection (no sudo required)
update_traffic_stats() {
    mkdir -p "$PERSIST_DIR"
    local cumulative_file="$PERSIST_DIR/cumulative_data"
    local snapshot_file="$PERSIST_DIR/tracker_snapshot"
    local container_start_file="$PERSIST_DIR/container_start"
    
    # Check if we can write to files (fix ownership issues from sudo runs)
    if [ -f "$cumulative_file" ] && [ ! -w "$cumulative_file" ]; then
        chmod u+w "$cumulative_file" 2>/dev/null || rm -f "$cumulative_file" 2>/dev/null || true
    fi
    if [ -f "$snapshot_file" ] && [ ! -w "$snapshot_file" ]; then
        chmod u+w "$snapshot_file" 2>/dev/null || rm -f "$snapshot_file" 2>/dev/null || true
    fi
    if [ -f "$container_start_file" ] && [ ! -w "$container_start_file" ]; then
        chmod u+w "$container_start_file" 2>/dev/null || rm -f "$container_start_file" 2>/dev/null || true
    fi
    
    # Get current container start time
    local current_start=$(get_container_start_time)
    local stored_start=""
    [ -f "$container_start_file" ] && stored_start=$(cat "$container_start_file")
    
    # If container restarted, reset cumulative data
    if [ "$current_start" != "$stored_start" ]; then
        echo "$current_start" > "$container_start_file"
        fix_file_ownership "$container_start_file"
        > "$cumulative_file"
        > "$snapshot_file"
    fi
    
    # Extract active IPs from /proc/net/tcp inside containers
    > "$snapshot_file"
    local temp_ips="/tmp/tracker_ips_$$.tmp"
    local temp_tcp="/tmp/tracker_tcp_$$.tmp"
    > "$temp_ips"
    
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local cname=$(get_container_name "$i")
        
        # Get /proc/net/tcp data and save to temp file
        $DOCKER_BIN exec "$cname" cat /proc/net/tcp 2>/dev/null > "$temp_tcp"
        
        # Process the file (skip header line)
        tail -n +2 "$temp_tcp" | while read line; do
            # Extract remote address (3rd column: rem_address)
            local rem_addr=$(echo "$line" | awk '{print $3}')
            local rem_ip_hex=$(echo "$rem_addr" | cut -d':' -f1)
            
            # Skip if empty or invalid
            [ -z "$rem_ip_hex" ] && continue
            [ ${#rem_ip_hex} -ne 8 ] && continue
            
            # Convert hex to IP
            local ip=$(hex_to_ip "$rem_ip_hex")
            
            # Skip private/local IPs
            echo "$ip" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.|169\.254\.)' && continue
            
            echo "$ip"
        done >> "$temp_ips"
    done
    rm -f "$temp_tcp"
    
    # Get unique IPs and do GeoIP lookup
    sort -u "$temp_ips" | while read -r ip; do
        [ -z "$ip" ] && continue
        
        # Try to get country for this IP (GeoIP)
        local country="Unknown"
        if command -v mmdblookup >/dev/null 2>&1; then
            local mmdb_path="${GEOIP_DB_PATH:-}"
            # Try multiple paths in order of preference
            if [ -z "$mmdb_path" ] || [ ! -f "$mmdb_path" ]; then
                for db in "$INSTALL_DIR/geoip/dbip-country-lite.mmdb" \
                          "$INSTALL_DIR/geoip/GeoLite2-Country.mmdb" \
                          "/usr/local/share/GeoIP/dbip-country-lite.mmdb" \
                          "/usr/share/GeoIP/dbip-country-lite.mmdb"; do
                    if [ -f "$db" ]; then
                        mmdb_path="$db"
                        break
                    fi
                done
            fi
            if [ -n "$mmdb_path" ] && [ -f "$mmdb_path" ]; then
                country=$(mmdblookup --file "$mmdb_path" --ip "$ip" country names en 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | head -1)
                [ -z "$country" ] && country="Unknown"
            fi
        elif command -v geoiplookup >/dev/null 2>&1; then
            country=$(geoiplookup "$ip" 2>/dev/null | awk -F': ' '{print $2}' | head -1)
            [ -z "$country" ] && country="Unknown"
        fi
        
        # Normalize country names
        country=$(echo "$country" | sed 's/Iran, Islamic Republic of/Iran - #FreeIran/' | sed 's/Moldova, Republic of/Moldova/')
        
        # Add to snapshot (IP|Country)
        echo "${ip}|${country}" >> "$snapshot_file"
    done
    rm -f "$temp_ips"
    fix_file_ownership "$snapshot_file"
    
    # Update cumulative_data from Docker STATS (Up/Down bytes from container logs)
    local total_up=0
    local total_down=0
    
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local cname=$(get_container_name "$i")
        local stat_line=$($DOCKER_BIN logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        
        if [ -n "$stat_line" ]; then
            # Extract Up: and Down: values (e.g., "Up: 12.90 GB | Down: 120.70 GB")
            local up_str=$(echo "$stat_line" | sed -n 's/.*Up:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
            local down_str=$(echo "$stat_line" | sed -n 's/.*Down:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
            
            # Convert to bytes
            if [ -n "$up_str" ]; then
                local up_val=$(echo "$up_str" | awk '{print $1}')
                local up_unit=$(echo "$up_str" | awk '{print $2}')
                local up_bytes=$(awk -v val="$up_val" -v unit="$up_unit" 'BEGIN{
                    u=toupper(unit); gsub(/I/,"",u);
                    if (u ~ /^TB/) val*=1099511627776;
                    else if (u ~ /^GB/) val*=1073741824;
                    else if (u ~ /^MB/) val*=1048576;
                    else if (u ~ /^KB/) val*=1024;
                    printf "%.0f", val
                }')
                total_up=$((total_up + up_bytes))
            fi
            
            if [ -n "$down_str" ]; then
                local down_val=$(echo "$down_str" | awk '{print $1}')
                local down_unit=$(echo "$down_str" | awk '{print $2}')
                local down_bytes=$(awk -v val="$down_val" -v unit="$down_unit" 'BEGIN{
                    u=toupper(unit); gsub(/I/,"",u);
                    if (u ~ /^TB/) val*=1099511627776;
                    else if (u ~ /^GB/) val*=1073741824;
                    else if (u ~ /^MB/) val*=1048576;
                    else if (u ~ /^KB/) val*=1024;
                    printf "%.0f", val
                }')
                total_down=$((total_down + down_bytes))
            fi
        fi
    done
    
    # Update cumulative_data with aggregate traffic by country
    # Distribute traffic proportionally across countries based on IP counts
    if [ -s "$snapshot_file" ] && [ "$total_up" -gt 0 ]; then
        # Count IPs per country
        declare -A country_counts
        local total_ips=0
        
        while IFS='|' read -r ip country; do
            [ -z "$country" ] && continue
            country_counts["$country"]=$((${country_counts["$country"]:-0} + 1))
            total_ips=$((total_ips + 1))
        done < "$snapshot_file"
        
        # Distribute traffic proportionally and write to cumulative_data
        > "$cumulative_file"
        for country in "${!country_counts[@]}"; do
            local count=${country_counts["$country"]}
            local proportion=$(awk "BEGIN {printf \"%.4f\", $count / $total_ips}")
            local country_down=$(awk "BEGIN {printf \"%.0f\", $total_down * $proportion}")
            local country_up=$(awk "BEGIN {printf \"%.0f\", $total_up * $proportion}")
            echo "${country}|${country_down}|${country_up}" >> "$cumulative_file"
        done
        fix_file_ownership "$cumulative_file"
    fi
}

# Main loop
load_peak_connections
while true; do
    # Update connection stats
    totals=$(get_totals)
    connected=$(echo "$totals" | cut -d'|' -f1)
    connecting=$(echo "$totals" | cut -d'|' -f2)
    if [ -n "$connected" ] && [ "$connected" -gt "$_PEAK_CONNECTIONS" ] 2>/dev/null; then
        _PEAK_CONNECTIONS=$connected
        save_peak_connections
    fi
    record_connection_history "${connected:-0}" "${connecting:-0}"
    
    # Update traffic stats (every cycle)
    update_traffic_stats
    
    sleep 60
done
EOF
    chmod +x "$INSTALL_DIR/conduit-tracker.sh"
}

setup_tracker_service() {
    if [ "$TRACKER_ENABLED" != "true" ]; then
        stop_tracker_service
        return 0
    fi
    if is_tracker_active; then
        return 0
    fi
    regenerate_tracker_script
    nohup "$INSTALL_DIR/conduit-tracker.sh" >> "$TRACKER_LOG_FILE" 2>&1 &
    echo $! > "$TRACKER_PID_FILE"
}

restart_tracker() {
    echo -e "${YELLOW}Restarting tracker...${NC}"
    stop_tracker_service
    sleep 1
    regenerate_tracker_script
    if [ "$TRACKER_ENABLED" = "true" ]; then
        nohup "$INSTALL_DIR/conduit-tracker.sh" >> "$TRACKER_LOG_FILE" 2>&1 &
        echo $! > "$TRACKER_PID_FILE"
        echo -e "${GREEN}✓ Tracker restarted with updated script${NC}"
    else
        echo -e "${YELLOW}Tracker is disabled - not starting${NC}"
    fi
    sleep 1
}

toggle_tracker() {
    if [ "$TRACKER_ENABLED" = "true" ]; then
        TRACKER_ENABLED=false
        stop_tracker_service
        if command -v save_settings >/dev/null 2>&1; then
            save_settings
        else
            local settings_path="$INSTALL_DIR/settings.conf"
            local tmp="${settings_path}.tmp.$$"
        cat > "$tmp" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=$CONTAINER_COUNT
CONTAINER_PORT_BASE=$CONTAINER_PORT_BASE
DOCKER_CPUS=${DOCKER_CPUS:-}
DOCKER_MEMORY=${DOCKER_MEMORY:-}
TRACKER_ENABLED=${TRACKER_ENABLED:-true}
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL:-}"
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
EOF
            for i in $(seq 1 "$CONTAINER_COUNT"); do
                local mc_var="MAX_CLIENTS_${i}"
                local bw_var="BANDWIDTH_${i}"
                [ -n "${!mc_var}" ] && echo "${mc_var}=${!mc_var}" >> "$tmp"
                [ -n "${!bw_var}" ] && echo "${bw_var}=${!bw_var}" >> "$tmp"
            done
            mv "$tmp" "$settings_path"
        fi
        echo -e "${YELLOW}Tracker disabled${NC}"
    else
        TRACKER_ENABLED=true
        if command -v save_settings >/dev/null 2>&1; then
            save_settings
        else
            local settings_path="$INSTALL_DIR/settings.conf"
            local tmp="${settings_path}.tmp.$$"
            cat > "$tmp" << EOF
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=$CONTAINER_COUNT
CONTAINER_PORT_BASE=$CONTAINER_PORT_BASE
DOCKER_CPUS=${DOCKER_CPUS:-}
DOCKER_MEMORY=${DOCKER_MEMORY:-}
TRACKER_ENABLED=${TRACKER_ENABLED:-true}
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL:-}"
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
EOF
            for i in $(seq 1 "$CONTAINER_COUNT"); do
                local mc_var="MAX_CLIENTS_${i}"
                local bw_var="BANDWIDTH_${i}"
                [ -n "${!mc_var}" ] && echo "${mc_var}=${!mc_var}" >> "$tmp"
                [ -n "${!bw_var}" ] && echo "${bw_var}=${!bw_var}" >> "$tmp"
            done
            mv "$tmp" "$settings_path"
        fi
        setup_tracker_service
        echo -e "${GREEN}Tracker enabled${NC}"
    fi
}

# ─── Telegram Bot Functions ───────────────────────────────────────────────────

escape_telegram_markdown() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\*/\\*}"
    text="${text//_/\\_}"
    text="${text//\`/\\\`}"
    text="${text//\[/\\[}"
    text="${text//\]/\\]}"
    echo "$text"
}

telegram_send_message() {
    local message="$1"
    { [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; } && return 1
    local label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
    label=$(escape_telegram_markdown "$label")
    local _ip=""
    if command -v curl >/dev/null 2>&1; then
        _ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
    fi
    if [ -n "$_ip" ]; then
        message="[${label} | ${_ip}] ${message}"
    else
        message="[${label}] ${message}"
    fi
    local response
    response=$(curl -s --max-time 10 --max-filesize 1048576 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$message" \
        --data-urlencode "parse_mode=Markdown" 2>/dev/null)
    [ $? -ne 0 ] && return 1
    echo "$response" | grep -q '"ok":true' && return 0
    return 1
}

telegram_get_chat_id() {
    local response
    response=$(curl -s --max-time 10 --max-filesize 1048576 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" 2>/dev/null)
    [ -z "$response" ] && return 1
    echo "$response" | grep -q '"ok":true' || return 1
    local chat_id=""
    if command -v python3 &>/dev/null; then
        chat_id=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    msgs=d.get('result',[])
    if msgs:
        print(msgs[-1]['message']['chat']['id'])
except: pass
" <<< "$response" 2>/dev/null)
    fi
    if [ -z "$chat_id" ]; then
        chat_id=$(echo "$response" | grep -o '"chat"[[:space:]]*:[[:space:]]*{[[:space:]]*"id"[[:space:]]*:[[:space:]]*-*[0-9]*' | grep -o -- '-*[0-9]*$' | tail -1 2>/dev/null)
    fi
    if [ -n "$chat_id" ]; then
        if ! echo "$chat_id" | grep -qE '^-?[0-9]+$'; then
            return 1
        fi
        TELEGRAM_CHAT_ID="$chat_id"
        return 0
    fi
    return 1
}

telegram_build_report() {
    local report="📊 *Conduit Status Report*"
    report+=$'\n'
    report+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    report+=$'\n'
    report+=$'\n'

    # Container status & uptime (check all containers, use earliest start)
    local running_count=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running_count=${running_count:-0}
    local total=$CONTAINER_COUNT
    if [ "$running_count" -gt 0 ]; then
        local earliest_start=""
        for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
            local cname=$(get_container_name $i)
            local started=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
            if [ -n "$started" ]; then
                local se=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$started" +%s 2>/dev/null || date -d "$started" +%s 2>/dev/null || echo 0)
                if [ -z "$earliest_start" ] || [ "$se" -lt "$earliest_start" ] 2>/dev/null; then
                    earliest_start=$se
                fi
            fi
        done
        if [ -n "$earliest_start" ] && [ "$earliest_start" -gt 0 ] 2>/dev/null; then
            local now=$(date +%s)
            local up=$((now - earliest_start))
            local days=$((up / 86400))
            local hours=$(( (up % 86400) / 3600 ))
            local mins=$(( (up % 3600) / 60 ))
            if [ "$days" -gt 0 ]; then
                report+="⏱ Uptime: ${days}d ${hours}h ${mins}m"
            else
                report+="⏱ Uptime: ${hours}h ${mins}m"
            fi
            report+=$'\n'
        fi
    fi
    report+="📦 Containers: ${running_count}/${total} running"
    report+=$'\n'

    # Uptime percentage + streak
    local uptime_log="$INSTALL_DIR/traffic_stats/uptime_log"
    if [ -s "$uptime_log" ]; then
        local cutoff_24h=$(( $(date +%s) - 86400 ))
        local t24=$(awk -F'|' -v c="$cutoff_24h" '$1+0>=c' "$uptime_log" 2>/dev/null | wc -l)
        local u24=$(awk -F'|' -v c="$cutoff_24h" '$1+0>=c && $2+0>0' "$uptime_log" 2>/dev/null | wc -l)
        if [ "${t24:-0}" -gt 0 ] 2>/dev/null; then
            local avail_24h=$(awk "BEGIN {printf \"%.1f\", ($u24/$t24)*100}" 2>/dev/null || echo "0")
            report+="📈 Availability: ${avail_24h}% (24h)"
            report+=$'\n'
        fi
        # Streak: consecutive minutes at end of log with running > 0
        local streak_mins=$(awk -F'|' '{a[NR]=$2+0} END{n=0; for(i=NR;i>=1;i--){if(a[i]<=0) break; n++} print n}' "$uptime_log" 2>/dev/null)
        if [ "${streak_mins:-0}" -gt 0 ] 2>/dev/null; then
            local sd=$((streak_mins / 1440)) sh=$(( (streak_mins % 1440) / 60 )) sm=$((streak_mins % 60))
            local streak_str=""
            [ "$sd" -gt 0 ] && streak_str+="${sd}d "
            streak_str+="${sh}h ${sm}m"
            report+="🔥 Streak: ${streak_str}"
            report+=$'\n'
        fi
    fi

    # Connected peers + connecting (matching TUI format)
    local total_peers=0
    local total_connecting=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local last_stat=$(docker logs --tail 400 "$cname" 2>&1 | grep "STATS" | tail -1)
        local peers=$(echo "$last_stat" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
        local cing=$(echo "$last_stat" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p')
        total_peers=$((total_peers + ${peers:-0}))
        total_connecting=$((total_connecting + ${cing:-0}))
    done
    report+="👥 Clients: ${total_peers} connected, ${total_connecting} connecting"
    report+=$'\n'

    # Active unique clients
    local snapshot_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snapshot_file" ]; then
        local active_clients=$(wc -l < "$snapshot_file" 2>/dev/null || echo 0)
        report+="👤 Total lifetime IPs served: ${active_clients}"
        report+=$'\n'
    fi

    # Total bandwidth served (all-time from cumulative_data)
    local data_file_bw="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$data_file_bw" ]; then
        local total_bytes=$(awk -F'|' '{s+=$2+$3} END{print s+0}' "$data_file_bw" 2>/dev/null)
        local total_served=""
        if [ "${total_bytes:-0}" -gt 0 ] 2>/dev/null; then
            total_served=$(awk "BEGIN {b=$total_bytes; if(b>1099511627776) printf \"%.2f TB\",b/1099511627776; else if(b>1073741824) printf \"%.2f GB\",b/1073741824; else printf \"%.1f MB\",b/1048576}" 2>/dev/null)
            report+="📡 Total served: ${total_served}"
            report+=$'\n'
        fi
    fi

    # CPU / RAM (normalize CPU by core count like dashboard)
    local stats=$(get_container_stats)
    local raw_cpu=$(echo "$stats" | awk '{print $1}')
    local cores=$(get_cpu_cores)
    local cpu=$(awk "BEGIN {printf \"%.1f%%\", ${raw_cpu%\%} / $cores}" 2>/dev/null || echo "$raw_cpu")
    local ram=$(echo "$stats" | awk '{print $2, $3, $4}')
    cpu=$(escape_telegram_markdown "$cpu")
    ram=$(escape_telegram_markdown "$ram")
    report+="🖥 CPU: ${cpu} | RAM: ${ram}"
    report+=$'\n'

    # Data usage (Linux-only interface stats; skip silently on macOS)
    if [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null; then
        local iface="${DATA_CAP_IFACE:-eth0}"
        if [ -r "/sys/class/net/${iface}/statistics/rx_bytes" ] && [ -r "/sys/class/net/${iface}/statistics/tx_bytes" ]; then
            local rx=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
            local tx=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)
            local total_used=$(( rx + tx + ${DATA_CAP_PRIOR_USAGE:-0} ))
            local used_gb=$(awk "BEGIN {printf \"%.2f\", $total_used/1073741824}" 2>/dev/null || echo "0")
            report+="📈 Data: ${used_gb} GB / ${DATA_CAP_GB} GB"
            report+=$'\n'
        fi
    fi

    # Container restart counts
    local total_restarts=0
    local restart_details=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local rc=$(docker inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null || echo 0)
        rc=${rc:-0}
        total_restarts=$((total_restarts + rc))
        [ "$rc" -gt 0 ] && restart_details+=" C${i}:${rc}"
    done
    if [ "$total_restarts" -gt 0 ]; then
        report+="🔄 Restarts: ${total_restarts}${restart_details}"
        report+=$'\n'
    fi

    # Top countries by connected peers (from tracker snapshot)
    local snap_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snap_file" ]; then
        local top_peers
        top_peers=$(awk -F'|' '{if($2!="") cnt[$2]++} END{for(c in cnt) print cnt[c]"|"c}' "$snap_file" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_peers" ]; then
            report+="🗺 Top by peers:"
            report+=$'\n'
            while IFS='|' read -r cnt country; do
                [ -z "$country" ] && continue
                local safe_c=$(escape_telegram_markdown "$country")
                report+="  • ${safe_c}: ${cnt} clients"
                report+=$'\n'
            done <<< "$top_peers"
        fi
    fi

    # Top countries by upload
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$data_file" ]; then
        local top_countries
        top_countries=$(awk -F'|' '{if($1!="" && $3+0>0) bytes[$1]+=$3+0} END{for(c in bytes) print bytes[c]"|"c}' "$data_file" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_countries" ]; then
            report+="🌍 Top by upload:"
            report+=$'\n'
            local total_upload=$(awk -F'|' '{s+=$3+0} END{print s+0}' "$data_file" 2>/dev/null)
            while IFS='|' read -r bytes country; do
                [ -z "$country" ] && continue
                local pct=0
                [ "$total_upload" -gt 0 ] 2>/dev/null && pct=$(awk "BEGIN {printf \"%.0f\", ($bytes/$total_upload)*100}" 2>/dev/null || echo 0)
                local safe_country=$(escape_telegram_markdown "$country")
                local fmt=$(awk "BEGIN {b=$bytes; if(b>1073741824) printf \"%.1f GB\",b/1073741824; else if(b>1048576) printf \"%.1f MB\",b/1048576; else printf \"%.1f KB\",b/1024}" 2>/dev/null)
                report+="  • ${safe_country}: ${pct}% (${fmt})"
                report+=$'\n'
            done <<< "$top_countries"
        fi
    fi

    echo "$report"
}

telegram_test_message() {
    local interval_label="${TELEGRAM_INTERVAL:-6}"
    local report=$(telegram_build_report)
    local message="✅ *Conduit Manager Connected!*

🔗 *What is Psiphon Conduit?*
You are running a Psiphon relay node that helps people in censored regions access the open internet.

📬 *What this bot sends you every ${interval_label}h:*
• Container status & uptime
• Connected peers count
• Upload & download totals
• CPU & RAM usage
• Data cap usage (if set)
• Top countries being served

⚠️ *Alerts:*
If a container gets stuck and is auto-restarted, you will receive an immediate alert.

━━━━━━━━━━━━━━━━━━━━
🎮 *Available Commands:*
━━━━━━━━━━━━━━━━━━━━
/status — Full status report on demand
/peers — Show connected & connecting clients
/uptime — Uptime for each container
/containers — List all containers with status
/start\_N — Start container N (e.g. /start\_1)
/stop\_N — Stop container N (e.g. /stop\_2)
/restart\_N — Restart container N (e.g. /restart\_1)

Replace N with the container number (1+).

━━━━━━━━━━━━━━━━━━━━
📊 *Your first report:*
━━━━━━━━━━━━━━━━━━━━

${report}"
    if telegram_send_message "$message"; then
        mkdir -p "$INSTALL_DIR/traffic_stats"
        echo "$(date +%s)" > "$INSTALL_DIR/traffic_stats/.last_report_ts"
        fix_file_ownership "$INSTALL_DIR/traffic_stats/.last_report_ts"
        return 0
    fi
    return 1
}

telegram_generate_notify_script() {
    cat > "$INSTALL_DIR/telegram_notify.sh" << 'TGEOF'
#!/opt/homebrew/bin/bash
# Conduit Telegram Notification Service
# Runs as a background process, sends periodic status reports

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure docker/curl found when run via nohup (e.g. macOS has minimal PATH)
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
# Resolve docker at startup without running it (avoid hang if Docker daemon is slow/unavailable)
DOCKER_BIN=$(command -v docker 2>/dev/null)
[ -z "$DOCKER_BIN" ] && [ -x /opt/homebrew/bin/docker ] && DOCKER_BIN=/opt/homebrew/bin/docker
[ -z "$DOCKER_BIN" ] && [ -x /usr/local/bin/docker ] && DOCKER_BIN=/usr/local/bin/docker
DOCKER_BIN=${DOCKER_BIN:-docker}
export DOCKER_BIN

[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"

# Exit if not configured
[ "$TELEGRAM_ENABLED" != "true" ] && exit 0
[ -z "$TELEGRAM_BOT_TOKEN" ] && exit 0
[ -z "$TELEGRAM_CHAT_ID" ] && exit 0

# Helper function to fix file ownership when running as root
fix_file_ownership() {
    local file="$1"
    [ ! -e "$file" ] && return 0
    if [ "$EUID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
        chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$file" 2>/dev/null || true
    fi
}

# Cache server IP once at startup
_server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "")

timeout() {
    if command -v gtimeout &>/dev/null; then
        gtimeout "$@"
    elif command -v timeout &>/dev/null; then
        command timeout "$@"
    else
        shift
        "$@"
    fi
}

to_epoch() {
    local started="$1"
    date -j -f "%Y-%m-%dT%H:%M:%S" "$started" +%s 2>/dev/null || date -d "$started" +%s 2>/dev/null || echo 0
}

telegram_send() {
    local message="$1"
    # Prepend server label + IP (escape for Markdown)
    local label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
    label=$(escape_md "$label")
    if [ -n "$_server_ip" ]; then
        message="[${label} | ${_server_ip}] ${message}"
    else
        message="[${label}] ${message}"
    fi
    curl -s --max-time 10 --max-filesize 1048576 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$message" \
        --data-urlencode "parse_mode=Markdown" >/dev/null 2>&1
}

escape_md() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\*/\\*}"
    text="${text//_/\\_}"
    text="${text//\`/\\\`}"
    text="${text//\[/\\[}"
    text="${text//\]/\\]}"
    echo "$text"
}

get_container_name() {
    local i=$1
    if [ "$i" -le 1 ]; then
        echo "conduit"
    else
        echo "conduit-${i}"
    fi
}

get_cpu_cores() {
    local cores=1
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif command -v sysctl &>/dev/null; then
        cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    fi
    [ "$cores" -lt 1 ] 2>/dev/null && cores=1
    echo "$cores"
}

track_uptime() {
    local running=$($DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    echo "$(date +%s)|${running}" >> "$INSTALL_DIR/traffic_stats/uptime_log"
    fix_file_ownership "$INSTALL_DIR/traffic_stats/uptime_log"
    # Trim to 10080 lines (7 days of per-minute entries)
    local log_file="$INSTALL_DIR/traffic_stats/uptime_log"
    local lines=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    if [ "$lines" -gt 10080 ] 2>/dev/null; then
        tail -10080 "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
    fi
}

calc_uptime_pct() {
    local period_secs=${1:-86400}
    local log_file="$INSTALL_DIR/traffic_stats/uptime_log"
    [ ! -s "$log_file" ] && echo "0" && return
    local cutoff=$(( $(date +%s) - period_secs ))
    local total=0
    local up=0
    while IFS='|' read -r ts count; do
        [ "$ts" -lt "$cutoff" ] 2>/dev/null && continue
        total=$((total + 1))
        [ "$count" -gt 0 ] 2>/dev/null && up=$((up + 1))
    done < "$log_file"
    [ "$total" -eq 0 ] && echo "0" && return
    awk "BEGIN {printf \"%.1f\", ($up/$total)*100}" 2>/dev/null || echo "0"
}

rotate_cumulative_data() {
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    local marker="$INSTALL_DIR/traffic_stats/.last_rotation_month"
    local current_month=$(date '+%Y-%m')
    local last_month=""
    [ -f "$marker" ] && last_month=$(cat "$marker" 2>/dev/null)
    # First run: just set the marker, don't archive
    if [ -z "$last_month" ]; then
        echo "$current_month" > "$marker"
        return
    fi
    if [ "$current_month" != "$last_month" ] && [ -s "$data_file" ]; then
        cp "$data_file" "${data_file}.${last_month}"
        echo "$current_month" > "$marker"
        # Delete archives older than 3 months (portable: 90 days in seconds)
        local cutoff_ts=$(( $(date +%s) - 7776000 ))
        for archive in "$INSTALL_DIR/traffic_stats/cumulative_data."[0-9][0-9][0-9][0-9]-[0-9][0-9]; do
            [ ! -f "$archive" ] && continue
            local archive_mtime=$(stat -c %Y "$archive" 2>/dev/null || stat -f %m "$archive" 2>/dev/null || echo 0)
            if [ "$archive_mtime" -gt 0 ] && [ "$archive_mtime" -lt "$cutoff_ts" ] 2>/dev/null; then
                rm -f "$archive"
            fi
        done
    fi
}

check_alerts() {
    [ "$TELEGRAM_ALERTS_ENABLED" != "true" ] && return
    local now=$(date +%s)
    local cooldown=3600

    # CPU + RAM check (single docker stats call)
    local conduit_containers=$($DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep "^conduit" 2>/dev/null || true)
    local stats_lines=""
    if [ -n "$conduit_containers" ]; then
        stats_lines=$(timeout 10 $DOCKER_BIN stats --no-stream --format "{{.CPUPerc}} {{.MemPerc}}" $conduit_containers 2>/dev/null)
    fi
    
    # Sum CPU across all containers, find max RAM
    local total_cpu=0
    local max_ram=0
    local cores=$(get_cpu_cores)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local raw_cpu=$(echo "$line" | awk '{print $1}')
        local ram_pct=$(echo "$line" | awk '{print $2}')
        
        # Remove % and accumulate CPU
        local cpu_num=${raw_cpu%\%}
        total_cpu=$(awk "BEGIN {print $total_cpu + ${cpu_num:-0}}" 2>/dev/null || echo "$total_cpu")
        
        # Track max RAM
        local ram_num=${ram_pct%\%}
        ram_num=${ram_num%%.*}
        if [ "${ram_num:-0}" -gt "$max_ram" ] 2>/dev/null; then
            max_ram=$ram_num
        fi
    done <<< "$stats_lines"
    
    # Normalize total CPU by number of cores
    local cpu_val=$(awk "BEGIN {printf \"%.0f\", $total_cpu / $cores}" 2>/dev/null || echo 0)
    if [ "${cpu_val:-0}" -gt 90 ] 2>/dev/null; then
        cpu_breach=$((cpu_breach + 1))
    else
        cpu_breach=0
    fi
    if [ "$cpu_breach" -ge 3 ] && [ $((now - last_alert_cpu)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "⚠️ *Alert: High CPU*
CPU usage at ${cpu_val}% for 3\+ minutes"
        last_alert_cpu=$now
        cpu_breach=0
    fi

    if [ "${max_ram:-0}" -gt 90 ] 2>/dev/null; then
        ram_breach=$((ram_breach + 1))
    else
        ram_breach=0
    fi
    if [ "$ram_breach" -ge 3 ] && [ $((now - last_alert_ram)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "⚠️ *Alert: High RAM*
Memory usage at ${max_ram}% for 3\+ minutes"
        last_alert_ram=$now
        ram_breach=0
    fi

    # All containers down
    local running=$($DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    if [ "$running" -eq 0 ] 2>/dev/null && [ $((now - last_alert_down)) -ge $cooldown ] 2>/dev/null; then
        telegram_send "🔴 *Alert: All containers down*
No Conduit containers are running\!"
        last_alert_down=$now
    fi

    # Zero peers for 2+ hours (skip on macOS - peer tracking unreliable in background)
    if [ "$(uname -s 2>/dev/null)" != "Darwin" ]; then
        local total_peers=0
        for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
            local cname=$(get_container_name $i)
            local last_stat=$(timeout 5 $DOCKER_BIN logs --tail 400 "$cname" 2>&1 | grep "STATS" | tail -1)
            local peers=$(echo "$last_stat" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
            total_peers=$((total_peers + ${peers:-0}))
        done
        if [ "$total_peers" -eq 0 ] 2>/dev/null; then
            if [ "$zero_peers_since" -eq 0 ] 2>/dev/null; then
                zero_peers_since=$now
            elif [ $((now - zero_peers_since)) -ge 7200 ] && [ $((now - last_alert_peers)) -ge $cooldown ] 2>/dev/null; then
                telegram_send "⚠️ *Alert: Zero peers*
No connected peers for 2\+ hours"
                last_alert_peers=$now
                zero_peers_since=$now
            fi
        else
            zero_peers_since=0
        fi
    fi
}

record_snapshot() {
    local running=$($DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    local total_peers=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local last_stat=$($DOCKER_BIN logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        local peers=$(echo "$last_stat" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
        total_peers=$((total_peers + ${peers:-0}))
    done
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    local total_bw=0
    [ -s "$data_file" ] && total_bw=$(awk -F'|' '{s+=$2+$3} END{print s+0}' "$data_file" 2>/dev/null)
    echo "$(date +%s)|${total_peers}|${total_bw:-0}|${running}" >> "$INSTALL_DIR/traffic_stats/report_snapshots"
    fix_file_ownership "$INSTALL_DIR/traffic_stats/report_snapshots"
    # Trim to 720 entries
    local snap_file="$INSTALL_DIR/traffic_stats/report_snapshots"
    local lines=$(wc -l < "$snap_file" 2>/dev/null || echo 0)
    if [ "$lines" -gt 720 ] 2>/dev/null; then
        tail -720 "$snap_file" > "${snap_file}.tmp" && mv "${snap_file}.tmp" "$snap_file"
    fi
}

build_summary() {
    local period_label="$1"
    local period_secs="$2"
    local snap_file="$INSTALL_DIR/traffic_stats/report_snapshots"
    [ ! -s "$snap_file" ] && return
    local cutoff=$(( $(date +%s) - period_secs ))
    local peak_peers=0
    local sum_peers=0
    local count=0
    local first_bw=0
    local last_bw=0
    local got_first=false
    while IFS='|' read -r ts peers bw running; do
        [ "$ts" -lt "$cutoff" ] 2>/dev/null && continue
        count=$((count + 1))
        sum_peers=$((sum_peers + ${peers:-0}))
        [ "${peers:-0}" -gt "$peak_peers" ] 2>/dev/null && peak_peers=${peers:-0}
        if [ "$got_first" = false ]; then
            first_bw=${bw:-0}
            got_first=true
        fi
        last_bw=${bw:-0}
    done < "$snap_file"
    [ "$count" -eq 0 ] && return

    local avg_peers=$((sum_peers / count))
    local period_bw=$((${last_bw:-0} - ${first_bw:-0}))
    [ "$period_bw" -lt 0 ] 2>/dev/null && period_bw=0
    local bw_fmt=$(awk "BEGIN {b=$period_bw; if(b>1099511627776) printf \"%.2f TB\",b/1099511627776; else if(b>1073741824) printf \"%.2f GB\",b/1073741824; else printf \"%.1f MB\",b/1048576}" 2>/dev/null)
    local uptime_pct=$(calc_uptime_pct "$period_secs")

    # New countries detection
    local countries_file="$INSTALL_DIR/traffic_stats/known_countries"
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    local new_countries=""
    if [ -s "$data_file" ]; then
        local current_countries=$(awk -F'|' '{if($1!="") print $1}' "$data_file" 2>/dev/null | sort -u)
        if [ -f "$countries_file" ]; then
            new_countries=$(comm -23 <(echo "$current_countries") <(sort "$countries_file") 2>/dev/null | head -5 | tr '\n' ', ' | sed 's/,$//')
        fi
        echo "$current_countries" > "$countries_file"
        fix_file_ownership "$countries_file"
    fi

    local msg="📋 *${period_label} Summary*"
    msg+=$'\n'
    msg+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    msg+=$'\n'
    msg+=$'\n'
    msg+="📊 Bandwidth served: ${bw_fmt}"
    msg+=$'\n'
    msg+="👥 Peak peers: ${peak_peers} | Avg: ${avg_peers}"
    msg+=$'\n'
    msg+="⏱ Uptime: ${uptime_pct}%"
    msg+=$'\n'
    msg+="📈 Data points: ${count}"
    if [ -n "$new_countries" ]; then
        local safe_new=$(escape_md "$new_countries")
        msg+=$'\n'"🆕 New countries: ${safe_new}"
    fi

    telegram_send "$msg"
}

process_commands() {
    local offset_file="$INSTALL_DIR/traffic_stats/last_update_id"
    local offset=0
    [ -f "$offset_file" ] && offset=$(cat "$offset_file" 2>/dev/null)
    offset=${offset:-0}
    # Ensure numeric
    [ "$offset" -eq "$offset" ] 2>/dev/null || offset=0

    local response
    response=$(curl -s --max-time 10 --max-filesize 1048576 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$((offset + 1))&timeout=0" 2>/dev/null)
    [ -z "$response" ] && return

    # Parse with python3 if available, otherwise skip
    if ! command -v python3 &>/dev/null; then
        return
    fi

    local parsed
    parsed=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    if not data.get('ok'): sys.exit(0)
    results = data.get('result', [])
    if not results: sys.exit(0)
    for r in results:
        uid = r.get('update_id', 0)
        msg = r.get('message', {})
        chat_id = msg.get('chat', {}).get('id', 0)
        text = msg.get('text', '')
        if str(chat_id) == '$TELEGRAM_CHAT_ID' and text.startswith('/'):
            print(f'{uid}|{text}')
        else:
            print(f'{uid}|')
except Exception:
    # On parse failure, try to extract max update_id to avoid re-fetching
    try:
        data = json.loads(sys.argv[1])
        results = data.get('result', [])
        if results:
            max_uid = max(r.get('update_id', 0) for r in results)
            if max_uid > 0:
                print(f'{max_uid}|')
    except Exception:
        pass
" "$response" 2>/dev/null)

    [ -z "$parsed" ] && return

    local max_id=$offset
    while IFS='|' read -r uid cmd; do
        [ -z "$uid" ] && continue
        [ "$uid" -gt "$max_id" ] 2>/dev/null && max_id=$uid
        case "$cmd" in
            /status|/status@*)
                local report=$(build_report)
                telegram_send "$report"
                ;;
            /peers|/peers@*)
                local total_peers=0
                local total_cing=0
                local _debug_stat=""
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    local last_stat=$($DOCKER_BIN logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
                    [ "$i" -eq 1 ] && _debug_stat="$last_stat"
                    local peers=$(echo "$last_stat" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
                    local cing=$(echo "$last_stat" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p')
                    total_peers=$((total_peers + ${peers:-0}))
                    total_cing=$((total_cing + ${cing:-0}))
                done
                mkdir -p "$INSTALL_DIR/traffic_stats"
                echo "last_stat=${_debug_stat}" > "$INSTALL_DIR/traffic_stats/.peers_debug"
                echo "total_peers=$total_peers total_cing=$total_cing" >> "$INSTALL_DIR/traffic_stats/.peers_debug"
                telegram_send "👥 Clients: ${total_peers} connected, ${total_cing} connecting"
                ;;
            /uptime|/uptime@*)
                local ut_msg="⏱ *Uptime Report*"
                ut_msg+=$'\n'
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    local is_running=$($DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep -c "^${cname}$" || true)
                    if [ "${is_running:-0}" -gt 0 ]; then
                        local started=$($DOCKER_BIN inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null)
                        if [ -n "$started" ]; then
                            local se=$(to_epoch "$started")
                            local diff=$(( $(date +%s) - se ))
                            local d=$((diff / 86400)) h=$(( (diff % 86400) / 3600 )) m=$(( (diff % 3600) / 60 ))
                            ut_msg+="📦 Container ${i}: ${d}d ${h}h ${m}m"
                        else
                            ut_msg+="📦 Container ${i}: ⚠ unknown"
                        fi
                    else
                        ut_msg+="📦 Container ${i}: 🔴 stopped"
                    fi
                    ut_msg+=$'\n'
                done
                local avail=$(calc_uptime_pct 86400)
                ut_msg+=$'\n'
                ut_msg+="📈 Availability: ${avail}% (24h)"
                telegram_send "$ut_msg"
                ;;
            /containers|/containers@*)
                local ct_msg="📦 *Container Status*"
                ct_msg+=$'\n'
                local docker_names=$($DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null)
                for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                    local cname=$(get_container_name $i)
                    ct_msg+=$'\n'
                    if echo "$docker_names" | grep -q "^${cname}$"; then
                        ct_msg+="C${i} (${cname}): 🟢 Running"
                        ct_msg+=$'\n'
                        local logs=$($DOCKER_BIN logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
                        if [ -n "$logs" ]; then
                            local c_conn=$(echo "$logs" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
                            local c_cing=$(echo "$logs" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p')
                            local c_up=$(echo "$logs" | sed -n 's/.*Up:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
                            local c_down=$(echo "$logs" | sed -n 's/.*Down:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
                            ct_msg+="  👥 Connected: ${c_conn:-0} | Connecting: ${c_cing:-0}"
                            ct_msg+=$'\n'
                            ct_msg+="  ⬆ Up: ${c_up:-N/A}  ⬇ Down: ${c_down:-N/A}"
                        else
                            ct_msg+="  ⚠ No stats available yet"
                        fi
                    else
                        ct_msg+="C${i} (${cname}): 🔴 Stopped"
                    fi
                    ct_msg+=$'\n'
                done
                ct_msg+=$'\n'
                ct_msg+="/restart\_N  /stop\_N  /start\_N — manage containers"
                telegram_send "$ct_msg"
                ;;
            /restart_*|/stop_*|/start_*)
                local action="${cmd%%_*}"     # /restart, /stop, or /start
                action="${action#/}"          # restart, stop, or start
                local num="${cmd#*_}"
                num="${num%%@*}"              # strip @botname suffix
                if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${CONTAINER_COUNT:-1}" ]; then
                    telegram_send "❌ Invalid container number: ${num}. Use 1-${CONTAINER_COUNT:-1}."
                else
                    local cname=$(get_container_name "$num")
                    if $DOCKER_BIN "$action" "$cname" >/dev/null 2>&1; then
                        local emoji="✅"
                        [ "$action" = "stop" ] && emoji="🛑"
                        [ "$action" = "start" ] && emoji="🟢"
                        telegram_send "${emoji} Container ${num} (${cname}): ${action} successful"
                    else
                        telegram_send "❌ Failed to ${action} container ${num} (${cname})"
                    fi
                fi
                ;;
            /help|/help@*)
                if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
                    telegram_send "📖 *Available Commands*
/status — Full status report
/uptime — Per-container uptime + 24h availability
/containers — Per-container status
/restart\_N — Restart container N
/stop\_N — Stop container N
/start\_N — Start container N
/help — Show this help"
                else
                    telegram_send "📖 *Available Commands*
/status — Full status report
/peers — Current peer count
/uptime — Per-container uptime + 24h availability
/containers — Per-container status
/restart\_N — Restart container N
/stop\_N — Stop container N
/start\_N — Start container N
/help — Show this help"
                fi
                ;;
        esac
    done <<< "$parsed"

    [ "$max_id" -gt "$offset" ] 2>/dev/null && echo "$max_id" > "$offset_file"
}

build_report() {
    local report="📊 *Conduit Status Report*"
    report+=$'\n'
    report+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    report+=$'\n'
    report+=$'\n'

    # Container status + uptime
    local running=$($DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" 2>/dev/null || true)
    running=${running:-0}
    local total=${CONTAINER_COUNT:-1}
    report+="📦 Containers: ${running}/${total} running"
    report+=$'\n'

    # Uptime percentage + streak
    local uptime_log="$INSTALL_DIR/traffic_stats/uptime_log"
    if [ -s "$uptime_log" ]; then
        local avail_24h=$(calc_uptime_pct 86400)
        report+="📈 Availability: ${avail_24h}% (24h)"
        report+=$'\n'
        # Streak: consecutive minutes at end of log with running > 0
        local streak_mins=$(awk -F'|' '{a[NR]=$2+0} END{n=0; for(i=NR;i>=1;i--){if(a[i]<=0) break; n++} print n}' "$uptime_log" 2>/dev/null)
        if [ "${streak_mins:-0}" -gt 0 ] 2>/dev/null; then
            local sd=$((streak_mins / 1440)) sh=$(( (streak_mins % 1440) / 60 )) sm=$((streak_mins % 60))
            local streak_str=""
            [ "$sd" -gt 0 ] && streak_str+="${sd}d "
            streak_str+="${sh}h ${sm}m"
            report+="🔥 Streak: ${streak_str}"
            report+=$'\n'
        fi
    fi

    # Uptime from earliest container
    local earliest_start=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local started=$($DOCKER_BIN inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null)
        [ -z "$started" ] && continue
        local se=$(to_epoch "$started")
        if [ -z "$earliest_start" ] || [ "$se" -lt "$earliest_start" ] 2>/dev/null; then
            earliest_start=$se
        fi
    done
    if [ -n "$earliest_start" ] && [ "$earliest_start" -gt 0 ] 2>/dev/null; then
        local now=$(date +%s)
        local diff=$((now - earliest_start))
        local days=$((diff / 86400))
        local hours=$(( (diff % 86400) / 3600 ))
        local mins=$(( (diff % 3600) / 60 ))
        report+="⏱ Uptime: ${days}d ${hours}h ${mins}m"
        report+=$'\n'
    fi

    # Peers (connected + connecting, matching TUI format) + Traffic from Docker STATS
    local total_peers=0
    local total_connecting=0
    local total_up_bytes=0
    local total_down_bytes=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local last_stat=$($DOCKER_BIN logs --tail 400 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
        [ -z "$last_stat" ] && continue
        
        # Parse peers
        local peers=$(echo "$last_stat" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
        local cing=$(echo "$last_stat" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p')
        total_peers=$((total_peers + ${peers:-0}))
        total_connecting=$((total_connecting + ${cing:-0}))
        
        # Parse Up/Down and convert to bytes (e.g. "12.90 GB" -> bytes)
        local c_up_val c_down_val
        IFS='|' read -r c_up_val c_down_val <<< $(echo "$last_stat" | awk '{
            up=""; down=""
            for(j=1;j<=NF;j++){
                if($j=="Up:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Down:/)break; up=up (up?" ":"") $k}}
                else if($j=="Down:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Uptime:/)break; down=down (down?" ":"") $k}}
            }
            printf "%s|%s", up, down
        }')
        
        if [ -n "$c_up_val" ]; then
            local up_val=$(echo "$c_up_val" | awk '{print $1}')
            local up_unit=$(echo "$c_up_val" | awk '{print $2}')
            local up_bytes=$(awk -v val="$up_val" -v unit="$up_unit" 'BEGIN{
                u=toupper(unit); gsub(/I/,"",u);
                if (u ~ /^KB/) val*=1024;
                else if (u ~ /^MB/) val*=1048576;
                else if (u ~ /^GB/) val*=1073741824;
                else if (u ~ /^TB/) val*=1099511627776;
                printf "%.0f", val
            }')
            total_up_bytes=$((total_up_bytes + up_bytes))
        fi
        if [ -n "$c_down_val" ]; then
            local down_val=$(echo "$c_down_val" | awk '{print $1}')
            local down_unit=$(echo "$c_down_val" | awk '{print $2}')
            local down_bytes=$(awk -v val="$down_val" -v unit="$down_unit" 'BEGIN{
                u=toupper(unit); gsub(/I/,"",u);
                if (u ~ /^KB/) val*=1024;
                else if (u ~ /^MB/) val*=1048576;
                else if (u ~ /^GB/) val*=1073741824;
                else if (u ~ /^TB/) val*=1099511627776;
                printf "%.0f", val
            }')
            total_down_bytes=$((total_down_bytes + down_bytes))
        fi
    done
    report+="👥 Clients: ${total_peers} connected, ${total_connecting} connecting"
    report+=$'\n'
    
    # Active unique clients (tracker-based)
    local snapshot_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snapshot_file" ]; then
        local active_clients=$(wc -l < "$snapshot_file" 2>/dev/null || echo 0)
        report+="👤 Total lifetime IPs served: ${active_clients}"
        report+=$'\n'
    fi

    # Total bandwidth served (all-time cumulative from tracker)
    local data_file_bw="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$data_file_bw" ]; then
        local total_bytes=$(awk -F'|' '{s+=$2+$3} END{print s+0}' "$data_file_bw" 2>/dev/null)
        if [ "${total_bytes:-0}" -gt 0 ] 2>/dev/null; then
            local total_served=$(awk "BEGIN {b=$total_bytes; if(b>1099511627776) printf \"%.2f TB\",b/1099511627776; else if(b>1073741824) printf \"%.2f GB\",b/1073741824; else printf \"%.1f MB\",b/1048576}" 2>/dev/null)
            report+="📡 Total served: ${total_served}"
            report+=$'\n'
        fi
    fi

    # CPU / RAM - aggregate from all containers (more robust than docker stats --no-stream)
    local total_cpu_pct=0
    local ram_display=""
    local stats_count=0
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local cstats=$(timeout 5 $DOCKER_BIN stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" "$cname" 2>/dev/null)
        if [ -n "$cstats" ]; then
            local c_cpu=$(echo "$cstats" | awk '{print $1}' | tr -d '%')
            total_cpu_pct=$(awk "BEGIN {printf \"%.2f\", ${total_cpu_pct:-0} + ${c_cpu:-0}}" 2>/dev/null)
            [ -z "$ram_display" ] && ram_display=$(echo "$cstats" | awk '{print $2, $3, $4}')
            stats_count=$((stats_count + 1))
        fi
    done
    if [ "$stats_count" -gt 0 ]; then
        local cores=$(get_cpu_cores)
        local cpu=$(awk "BEGIN {printf \"%.1f%%\", ${total_cpu_pct} / $cores}" 2>/dev/null || echo "$total_cpu_pct%")
        cpu=$(escape_md "$cpu")
        ram_display=$(escape_md "$ram_display")
        report+="🖥 CPU: ${cpu} | RAM: ${ram_display}"
        report+=$'\n'
    fi

    # Data usage (Linux-only interface stats; skip silently on macOS)
    if [ "${DATA_CAP_GB:-0}" -gt 0 ] 2>/dev/null; then
        local iface="${DATA_CAP_IFACE:-eth0}"
        if [ -r "/sys/class/net/${iface}/statistics/rx_bytes" ] && [ -r "/sys/class/net/${iface}/statistics/tx_bytes" ]; then
            local rx=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
            local tx=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)
            local total_used=$(( rx + tx + ${DATA_CAP_PRIOR_USAGE:-0} ))
            local used_gb=$(awk "BEGIN {printf \"%.2f\", $total_used/1073741824}" 2>/dev/null || echo "0")
            report+="📈 Data: ${used_gb} GB / ${DATA_CAP_GB} GB"
            report+=$'\n'
        fi
    fi

    # Container restart counts
    local total_restarts=0
    local restart_details=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i)
        local rc=$($DOCKER_BIN inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null || echo 0)
        rc=${rc:-0}
        total_restarts=$((total_restarts + rc))
        [ "$rc" -gt 0 ] && restart_details+=" C${i}:${rc}"
    done
    if [ "$total_restarts" -gt 0 ]; then
        report+="🔄 Restarts: ${total_restarts}${restart_details}"
        report+=$'\n'
    fi

    # Top countries by connected peers (from tracker snapshot)
    local snap_file="$INSTALL_DIR/traffic_stats/tracker_snapshot"
    if [ -s "$snap_file" ]; then
        local top_peers
        top_peers=$(awk -F'|' '{if($2!="") cnt[$2]++} END{for(c in cnt) print cnt[c]"|"c}' "$snap_file" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_peers" ]; then
            report+="🗺 Top by peers:"
            report+=$'\n'
            while IFS='|' read -r cnt country; do
                [ -z "$country" ] && continue
                local safe_c=$(escape_md "$country")
                report+="  • ${safe_c}: ${cnt} clients"
                report+=$'\n'
            done <<< "$top_peers"
        fi
    fi

    # Top countries by upload (all-time cumulative from tracker)
    local data_file="$INSTALL_DIR/traffic_stats/cumulative_data"
    if [ -s "$data_file" ]; then
        local top_countries
        top_countries=$(awk -F'|' '{if($1!="" && $3+0>0) bytes[$1]+=$3+0} END{for(c in bytes) print bytes[c]"|"c}' "$data_file" 2>/dev/null | sort -t'|' -k1 -nr | head -3)
        if [ -n "$top_countries" ]; then
            report+="🌍 Top by upload:"
            report+=$'\n'
            local total_upload=$(awk -F'|' '{s+=$3+0} END{print s+0}' "$data_file" 2>/dev/null)
            while IFS='|' read -r bytes country; do
                [ -z "$country" ] && continue
                local pct=0
                [ "$total_upload" -gt 0 ] 2>/dev/null && pct=$(awk "BEGIN {printf \"%.0f\", ($bytes/$total_upload)*100}" 2>/dev/null || echo 0)
                local safe_country=$(escape_md "$country")
                local fmt=$(awk "BEGIN {b=$bytes; if(b>1073741824) printf \"%.1f GB\",b/1073741824; else if(b>1048576) printf \"%.1f MB\",b/1048576; else printf \"%.1f KB\",b/1024}" 2>/dev/null)
                report+="  • ${safe_country}: ${pct}% (${fmt})"
                report+=$'\n'
            done <<< "$top_countries"
        fi
    fi

    echo "$report"
}

# State variables
cpu_breach=0
ram_breach=0
zero_peers_since=0
last_alert_cpu=0
last_alert_ram=0
last_alert_down=0
last_alert_peers=0
last_rotation_ts=0

# Ensure data directory exists
mkdir -p "$INSTALL_DIR/traffic_stats"

# Persist daily/weekly timestamps across restarts
_ts_dir="$INSTALL_DIR/traffic_stats"
last_daily_ts=$(cat "$_ts_dir/.last_daily_ts" 2>/dev/null || echo 0)
[ "$last_daily_ts" -eq "$last_daily_ts" ] 2>/dev/null || last_daily_ts=0
last_weekly_ts=$(cat "$_ts_dir/.last_weekly_ts" 2>/dev/null || echo 0)
[ "$last_weekly_ts" -eq "$last_weekly_ts" ] 2>/dev/null || last_weekly_ts=0
last_report_ts=$(cat "$_ts_dir/.last_report_ts" 2>/dev/null || echo 0)
[ "$last_report_ts" -eq "$last_report_ts" ] 2>/dev/null || last_report_ts=0

while true; do
    sleep 60

    # Re-read settings
    [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"

    # Exit if disabled
    [ "$TELEGRAM_ENABLED" != "true" ] && exit 0
    [ -z "$TELEGRAM_BOT_TOKEN" ] && exit 0

    # Core per-minute tasks
    process_commands
    track_uptime
    check_alerts

    # Daily rotation check (once per day, using wall-clock time)
    now_ts=$(date +%s)
    if [ $((now_ts - last_rotation_ts)) -ge 86400 ] 2>/dev/null; then
        rotate_cumulative_data
        last_rotation_ts=$now_ts
    fi

    # Daily summary (wall-clock, survives restarts)
    if [ "${TELEGRAM_DAILY_SUMMARY:-true}" = "true" ] && [ $((now_ts - last_daily_ts)) -ge 86400 ] 2>/dev/null; then
        build_summary "Daily" 86400
        last_daily_ts=$now_ts
        echo "$now_ts" > "$_ts_dir/.last_daily_ts"
        fix_file_ownership "$_ts_dir/.last_daily_ts"
    fi

    # Weekly summary (wall-clock, survives restarts)
    if [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" = "true" ] && [ $((now_ts - last_weekly_ts)) -ge 604800 ] 2>/dev/null; then
        build_summary "Weekly" 604800
        last_weekly_ts=$now_ts
        echo "$now_ts" > "$_ts_dir/.last_weekly_ts"
        fix_file_ownership "$_ts_dir/.last_weekly_ts"
    fi

    # Regular periodic report (wall-clock aligned to start hour)
    # Reports fire when current hour matches start_hour + N*interval
    interval_hours=${TELEGRAM_INTERVAL:-6}
    start_hour=${TELEGRAM_START_HOUR:-0}
    interval_secs=$((interval_hours * 3600))
    current_hour=$(date +%H | sed 's/^0//')
    # Check if this hour is a scheduled slot: (current_hour - start_hour) mod interval == 0
    hour_diff=$(( (current_hour - start_hour + 24) % 24 ))
    if [ "$interval_hours" -gt 0 ] && [ $((hour_diff % interval_hours)) -eq 0 ] 2>/dev/null; then
        # Only send once per slot (check if enough time passed since last report)
        if [ $((now_ts - last_report_ts)) -ge $((interval_secs - 120)) ] 2>/dev/null; then
            report=$(build_report)
            telegram_send "$report"
            record_snapshot
            last_report_ts=$now_ts
            echo "$now_ts" > "$_ts_dir/.last_report_ts"
            fix_file_ownership "$_ts_dir/.last_report_ts"
        fi
    fi
done
TGEOF
    chmod 700 "$INSTALL_DIR/telegram_notify.sh"
}

telegram_start_notify() {
    telegram_stop_notify
    telegram_generate_notify_script
    nohup "$INSTALL_DIR/telegram_notify.sh" >/dev/null 2>&1 &
    echo $! > "$INSTALL_DIR/telegram_notify.pid"
}

telegram_stop_notify() {
    if [ -f "$INSTALL_DIR/telegram_notify.pid" ]; then
        local pid=$(cat "$INSTALL_DIR/telegram_notify.pid" 2>/dev/null || true)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        rm -f "$INSTALL_DIR/telegram_notify.pid" 2>/dev/null || true
    fi
}

telegram_disable_service() {
    telegram_stop_notify
    TELEGRAM_ENABLED=false
}

show_telegram_menu() {
    while true; do
        # Reload settings from disk to reflect any changes
        [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
        clear
        print_header
        if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            # Already configured — show management menu
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  TELEGRAM NOTIFICATIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            local _sh="${TELEGRAM_START_HOUR:-0}"
            echo -e "  Status: ${GREEN}✓ Enabled${NC} (every ${TELEGRAM_INTERVAL}h starting at ${_sh}:00)"
            echo ""
            local alerts_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_ALERTS_ENABLED:-true}" != "true" ] && alerts_st="${RED}OFF${NC}"
            local daily_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_DAILY_SUMMARY:-true}" != "true" ] && daily_st="${RED}OFF${NC}"
            local weekly_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" != "true" ] && weekly_st="${RED}OFF${NC}"
            echo -e "  1. 📩 Send test message"
            echo -e "  2. ⏱  Change interval"
            echo -e "  3. ❌ Disable notifications"
            echo -e "  4. 🔄 Reconfigure (new bot/chat)"
            echo -e "  5. 🚨 Alerts (CPU/RAM/down):    ${alerts_st}"
            echo -e "  6. 📋 Daily summary:            ${daily_st}"
            echo -e "  7. 📊 Weekly summary:           ${weekly_st}"
            local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
            echo -e "  8. 🏷  Server label:            ${CYAN}${cur_label}${NC}"
            echo -e "  9. 🔁 Restart notification service"
            echo -e "  0. ← Back"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            read -p "  Enter choice: " tchoice < /dev/tty || return
            case "$tchoice" in
                1)
                    echo ""
                    echo -ne "  Sending test message... "
                    if telegram_test_message; then
                        echo -e "${GREEN}✓ Sent!${NC}"
                    else
                        echo -e "${RED}✗ Failed. Check your token/chat ID.${NC}"
                    fi
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                2)
                    echo ""
                    echo -e "  Select notification interval:"
                    echo -e "  1. Every 1 hour"
                    echo -e "  2. Every 3 hours"
                    echo -e "  3. Every 6 hours (recommended)"
                    echo -e "  4. Every 12 hours"
                    echo -e "  5. Every 24 hours"
                    echo ""
                    read -p "  Choice [1-5]: " ichoice < /dev/tty || true
                    case "$ichoice" in
                        1) TELEGRAM_INTERVAL=1 ;;
                        2) TELEGRAM_INTERVAL=3 ;;
                        3) TELEGRAM_INTERVAL=6 ;;
                        4) TELEGRAM_INTERVAL=12 ;;
                        5) TELEGRAM_INTERVAL=24 ;;
                        *) echo -e "  ${RED}Invalid choice${NC}"; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; continue ;;
                    esac
                    echo ""
                    echo -e "  What hour should reports start? (0-23, e.g. 8 = 8:00 AM)"
                    echo -e "  Reports will repeat every ${TELEGRAM_INTERVAL}h from this hour."
                    read -p "  Start hour [0-23] (default ${TELEGRAM_START_HOUR:-0}): " shchoice < /dev/tty || true
                    if [ -n "$shchoice" ] && [ "$shchoice" -ge 0 ] 2>/dev/null && [ "$shchoice" -le 23 ] 2>/dev/null; then
                        TELEGRAM_START_HOUR=$shchoice
                    fi
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Reports every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR:-0}:00${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                3)
                    TELEGRAM_ENABLED=false
                    save_settings
                    telegram_disable_service
                    echo -e "  ${GREEN}✓ Telegram notifications disabled${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                4)
                    telegram_setup_wizard
                    ;;
                9)
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Notification service restarted${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                5)
                    if [ "${TELEGRAM_ALERTS_ENABLED:-true}" = "true" ]; then
                        TELEGRAM_ALERTS_ENABLED=false
                        echo -e "  ${RED}✗ Alerts disabled${NC}"
                    else
                        TELEGRAM_ALERTS_ENABLED=true
                        echo -e "  ${GREEN}✓ Alerts enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                6)
                    if [ "${TELEGRAM_DAILY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_DAILY_SUMMARY=false
                        echo -e "  ${RED}✗ Daily summary disabled${NC}"
                    else
                        TELEGRAM_DAILY_SUMMARY=true
                        echo -e "  ${GREEN}✓ Daily summary enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                7)
                    if [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_WEEKLY_SUMMARY=false
                        echo -e "  ${RED}✗ Weekly summary disabled${NC}"
                    else
                        TELEGRAM_WEEKLY_SUMMARY=true
                        echo -e "  ${GREEN}✓ Weekly summary enabled${NC}"
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                8)
                    echo ""
                    local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
                    echo -e "  Current label: ${CYAN}${cur_label}${NC}"
                    echo -e "  This label appears in all Telegram messages to identify the server."
                    echo -e "  Leave blank to use hostname ($(hostname 2>/dev/null || echo 'unknown'))"
                    echo ""
                    read -p "  New label: " new_label < /dev/tty || true
                    # Sanitize label to prevent shell injection
                    if [ -n "$new_label" ]; then
                        if ! [[ "$new_label" =~ ^[A-Za-z0-9\ _.\-]+$ ]]; then
                            echo -e "  ${RED}✗ Invalid label. Only letters, numbers, spaces, underscores, dots, and hyphens are allowed.${NC}"
                            read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                            continue
                        fi
                    fi
                    TELEGRAM_SERVER_LABEL="${new_label}"
                    save_settings
                    telegram_start_notify
                    local display_label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
                    echo -e "  ${GREEN}✓ Server label set to: ${display_label}${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                0) return ;;
            esac
        elif [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            # Disabled but credentials exist — offer re-enable
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  TELEGRAM NOTIFICATIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            echo -e "  Status: ${RED}✗ Disabled${NC} (credentials saved)"
            echo ""
            echo -e "  1. ✅ Re-enable notifications (every ${TELEGRAM_INTERVAL:-6}h)"
            echo -e "  2. 🔄 Reconfigure (new bot/chat)"
            echo -e "  0. ← Back"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            read -p "  Enter choice: " tchoice < /dev/tty || return
            case "$tchoice" in
                1)
                    TELEGRAM_ENABLED=true
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Telegram notifications re-enabled${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                2)
                    telegram_setup_wizard
                    ;;
                0) return ;;
            esac
        else
            # Not configured — run wizard
            telegram_setup_wizard
            return
        fi
    done
}

telegram_setup_wizard() {
    # Save and restore variables on Ctrl+C
    local _saved_token="$TELEGRAM_BOT_TOKEN"
    local _saved_chatid="$TELEGRAM_CHAT_ID"
    local _saved_interval="$TELEGRAM_INTERVAL"
    local _saved_enabled="$TELEGRAM_ENABLED"
    local _saved_starthour="$TELEGRAM_START_HOUR"
    local _saved_label="$TELEGRAM_SERVER_LABEL"
    trap 'TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"; trap - SIGINT; echo; return' SIGINT
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "              ${BOLD}TELEGRAM NOTIFICATIONS SETUP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Step 1: Create a Telegram Bot${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Open Telegram and search for ${BOLD}@BotFather${NC}"
    echo -e "  2. Send ${YELLOW}/newbot${NC}"
    echo -e "  3. Choose a name (e.g. \"My Conduit Monitor\")"
    echo -e "  4. Choose a username (e.g. \"my_conduit_bot\")"
    echo -e "  5. BotFather will give you a token like:"
    echo -e "     ${YELLOW}123456789:ABCdefGHIjklMNOpqrsTUVwxyz${NC}"
    echo ""
    echo -e "  ${BOLD}Recommended:${NC} Send these commands to @BotFather:"
    echo -e "     ${YELLOW}/setjoingroups${NC} → Disable (prevents adding to groups)"
    echo -e "     ${YELLOW}/setprivacy${NC}   → Enable (limits message access)"
    echo ""
    echo -e "  ${YELLOW}⚠ OPSEC Note:${NC} Enabling Telegram notifications creates"
    echo -e "  outbound connections to api.telegram.org from this server."
    echo -e "  This traffic may be visible to your network provider."
    echo ""
    read -p "  Enter your bot token: " TELEGRAM_BOT_TOKEN < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; return; }
    echo ""
    # Trim whitespace
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN## }"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN%% }"
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        echo -e "  ${RED}No token entered. Setup cancelled.${NC}"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    # Validate token format
    if ! echo "$TELEGRAM_BOT_TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$'; then
        echo -e "  ${RED}Invalid token format. Should be like: 123456789:ABCdefGHI...${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    echo ""
    echo -e "  ${BOLD}Step 2: Get Your Chat ID${NC}"
    echo -e "  ${CYAN}────────────────────────${NC}"
    echo -e "  1. Open your new bot in Telegram"
    echo -e "  2. Send it the message: ${YELLOW}/start${NC}"
    echo ""
    echo -e "  ${YELLOW}Important:${NC} You MUST send ${BOLD}/start${NC} to the bot first!"
    echo -e "  The bot cannot respond to you until you do this."
    echo ""
    echo -e "  3. Press Enter here when done..."
    echo ""
    read -p "  Press Enter after sending /start to your bot... " < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"; return; }

    echo -ne "  Detecting chat ID... "
    local attempts=0
    TELEGRAM_CHAT_ID=""
    while [ $attempts -lt 3 ] && [ -z "$TELEGRAM_CHAT_ID" ]; do
        if telegram_get_chat_id; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 2
    done

    if [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo -e "${RED}✗ Could not detect chat ID${NC}"
        echo -e "  Make sure you sent /start to the bot and try again."
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi
    echo -e "${GREEN}✓ Chat ID: ${TELEGRAM_CHAT_ID}${NC}"

    echo ""
    echo -e "  ${BOLD}Step 3: Notification Interval${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Every 1 hour"
    echo -e "  2. Every 3 hours"
    echo -e "  3. Every 6 hours (recommended)"
    echo -e "  4. Every 12 hours"
    echo -e "  5. Every 24 hours"
    echo ""
    read -p "  Choice [1-5] (default 3): " ichoice < /dev/tty || true
    case "$ichoice" in
        1) TELEGRAM_INTERVAL=1 ;;
        2) TELEGRAM_INTERVAL=3 ;;
        4) TELEGRAM_INTERVAL=12 ;;
        5) TELEGRAM_INTERVAL=24 ;;
        *) TELEGRAM_INTERVAL=6 ;;
    esac

    echo ""
    echo -e "  ${BOLD}Step 4: Start Hour${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  What hour should reports start? (0-23, e.g. 8 = 8:00 AM)"
    echo -e "  Reports will repeat every ${TELEGRAM_INTERVAL}h from this hour."
    echo ""
    read -p "  Start hour [0-23] (default 0): " shchoice < /dev/tty || true
    if [ -n "$shchoice" ] && [ "$shchoice" -ge 0 ] 2>/dev/null && [ "$shchoice" -le 23 ] 2>/dev/null; then
        TELEGRAM_START_HOUR=$shchoice
    else
        TELEGRAM_START_HOUR=0
    fi

    echo ""
    echo -ne "  Sending test message... "
    if telegram_test_message; then
        echo -e "${GREEN}✓ Success!${NC}"
    else
        echo -e "${RED}✗ Failed to send. Check your token.${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT; return
    fi

    TELEGRAM_ENABLED=true
    save_settings
    telegram_start_notify

    trap - SIGINT
    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Telegram notifications enabled!${NC}"
    echo -e "  You'll receive reports every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR}:00."
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

# Helper: Fix volume permissions for conduit user (uid 1000)
fix_volume_permissions() {
    local idx=${1:-0}
    if [ "$idx" -eq 0 ]; then
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            local vol=$(get_volume_name "$i")
            docker run --rm -v "${vol}:/home/conduit/data" alpine \
                sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true
        done
    else
        local vol=$(get_volume_name "$idx")
        docker run --rm -v "${vol}:/home/conduit/data" alpine \
            sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true
    fi
}

# Helper: Start/recreate conduit container with current settings
run_conduit_container() {
    local idx=${1:-1}
    local name=$(get_container_name "$idx")
    local vol=$(get_volume_name "$idx")
    local mc=$(get_container_max_clients "$idx")
    local bw=$(get_container_bandwidth "$idx")
    local cpus=$(get_container_cpus "$idx")
    local mem=$(get_container_memory "$idx")
    local net_args="--network host"
    if [ "$OS_FAMILY" = "macos" ]; then
        # Docker Desktop does not support host networking; publish ports explicitly.
        local port=$(get_container_port "$idx")
        net_args="-p ${port}:443/tcp -p ${port}:443/udp"
    fi
    if docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
        docker rm -f "$name" 2>/dev/null || true
    fi
    local resource_args=""
    [ -n "$cpus" ] && resource_args+="--cpus $cpus "
    [ -n "$mem" ] && resource_args+="--memory $mem "
    # shellcheck disable=SC2086
    docker run -d \
        --name "$name" \
        --restart unless-stopped \
        -v "${vol}:/home/conduit/data" \
        $net_args \
        $resource_args \
        $CONDUIT_IMAGE \
        start --max-clients "$mc" --bandwidth "$bw" --stats-file "$STATS_FILE"
}

print_header() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    local inner_width=67
    local title="🚀  PSIPHON CONDUIT MANAGER v${VERSION}"
    local title_len=${#title}
    local emoji_width=0
    if [[ "$title" == *"🚀"* ]]; then
        emoji_width=1
    fi
    local visible_len=$((title_len + emoji_width))
    local pad_total=$((inner_width - visible_len))
    [ "$pad_total" -lt 0 ] && pad_total=0
    local pad_left=$((pad_total / 2))
    local pad_right=$((pad_total - pad_left))
    printf "║%*s%s%*s║\n" "$pad_left" "" "$title" "$pad_right" ""
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_live_stats_header() {
    local EL="\033[K"
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${EL}"
    local left=" 🚀 PSIPHON CONDUIT MANAGER v${VERSION} "
    local right="CONDUIT LIVE STATISTICS"
    local inner_width=67
    local left_trim="$left"
    local left_len=${#left_trim}
    local emoji_width=0
    if [[ "$left_trim" == *"🚀"* ]]; then
        emoji_width=1
    fi
    local right_len=${#right}
    local rem=$((inner_width - 2 - (left_len + emoji_width) - 1 - right_len))
    while [ "$rem" -lt 0 ] && [ "$left_len" -gt 0 ]; do
        left_len=$((left_len - 1))
        left_trim="${left_trim:0:$left_len}"
        if [[ "$left_trim" == *"🚀"* ]]; then
            emoji_width=1
        else
            emoji_width=0
        fi
        rem=$((inner_width - 2 - (left_len + emoji_width) - 1 - right_len))
    done
    [ "$rem" -lt 0 ] && rem=0
    printf "║  %s %s%*s║${EL}\n" "$left_trim" "$right" "$rem" ""
    echo -e "╠═══════════════════════════════════════════════════════════════════╣${EL}"
    if [ "$CONTAINER_COUNT" -gt 1 ]; then
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            local mc=$(get_container_max_clients "$i")
            local bw=$(get_container_bandwidth "$i")
            local bw_d="Unlimited"
            [ "$bw" != "-1" ] && bw_d="${bw} Mbps"
            local port_note=""
            if [ "$OS_FAMILY" = "macos" ]; then
                port_note=", port $(get_container_port "$i")"
            fi
            local line="$(get_container_name "$i"): ${mc} clients, ${bw_d}${port_note}"
            printf "║  ${GREEN}%-64s${CYAN}║${EL}\n" "$line"
        done
    else
        printf "║  Max Clients: ${GREEN}%-52s${CYAN}║${EL}\n" "${MAX_CLIENTS}"
        if [ "$BANDWIDTH" == "-1" ]; then
            printf "║  Bandwidth:   ${GREEN}%-52s${CYAN}║${EL}\n" "Unlimited"
        else
            printf "║  Bandwidth:   ${GREEN}%-52s${CYAN}║${EL}\n" "${BANDWIDTH} Mbps"
        fi
    fi
    echo -e "╚═══════════════════════════════════════════════════════════════════╝${EL}"
    echo -e "${NC}\033[K"
}



get_node_id() {
    local vol="${1:-conduit-data}"
    if ! docker volume inspect "$vol" >/dev/null 2>&1; then
        return
    fi
    if [ "$OS_FAMILY" = "macos" ]; then
        local key_json
        key_json=$(docker run --rm -v "${vol}:/home/conduit/data" alpine sh -c "cat /home/conduit/data/conduit_key.json 2>/dev/null" 2>/dev/null || true)
        if [ -n "$key_json" ]; then
            local key_b64
            key_b64=$(echo "$key_json" | grep "privateKeyBase64" | awk -F'"' '{print $4}')
            if [ -n "$key_b64" ]; then
                printf "%s" "$key_b64" | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; } | tail -c 32 | base64 | tr -d '=\n'
            fi
        fi
        return
    fi
    local mountpoint=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}')
    if [ -f "$mountpoint/conduit_key.json" ]; then
        cat "$mountpoint/conduit_key.json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; } | tail -c 32 | base64 | tr -d '=\n'
    fi
}

show_dashboard() {
    local stop_dashboard=0
    # Setup trap to catch signals gracefully
    trap 'stop_dashboard=1' SIGINT SIGTERM
    
    # Use alternate screen buffer if available for smoother experience
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l" # Hide cursor
    # Initial clear
    clear

    while [ $stop_dashboard -eq 0 ]; do
        # Move cursor to top-left (0,0)
        # We NO LONGER clear the screen here to avoid the "full black" flash
        if ! tput cup 0 0 2>/dev/null; then
            printf "\033[H"
        fi
        
        print_live_stats_header
        
        show_status "live"
        
        # Show Node ID in its own section
        if [ "$CONTAINER_COUNT" -gt 1 ]; then
            echo -e "${CYAN}═══ CONDUIT IDS ═══${NC}\033[K"
            for i in $(seq 1 "$CONTAINER_COUNT"); do
                local vol=$(get_volume_name "$i")
                local node_id=$(get_node_id "$vol")
                local port_note=""
                if [ "$OS_FAMILY" = "macos" ]; then
                    port_note=" (port $(get_container_port "$i"))"
                fi
                if [ -n "$node_id" ]; then
                    echo -e "  ${CYAN}$(get_container_name "$i")${NC}: ${CYAN}${node_id}${NC}${port_note}\033[K"
                else
                    echo -e "  ${CYAN}$(get_container_name "$i")${NC}: ${YELLOW}pending${NC}${port_note}\033[K"
                fi
            done
            echo -e "\033[K"
        else
            local node_id=$(get_node_id)
            if [ -n "$node_id" ]; then
                echo -e "${CYAN}═══ CONDUIT ID ═══${NC}\033[K"
                echo -e "  ${CYAN}${node_id}${NC}\033[K"
                echo -e "\033[K"
            fi
        fi

        echo -e "${BOLD}Refreshes every 5 seconds. Press any key to return to menu...${NC}\033[K"
        
        # Clear any leftover lines below the dashboard content (Erase to End of Display)
        # This only cleans up if the dashboard gets shorter
        if ! tput ed 2>/dev/null; then
            printf "\033[J"
        fi
        
        # Wait for keypress with multiple short intervals for better responsiveness
        # Total ~5 second refresh, but checks for input every 0.2s
        local waited=0
        while [ $waited -lt 25 ] && [ $stop_dashboard -eq 0 ]; do
            if read -t 0.2 -n 1 -s <> /dev/tty 2>/dev/null; then
                stop_dashboard=1
                break
            fi
            waited=$((waited + 1))
        done
    done
    
    echo -ne "\033[?25h" # Show cursor
    # Restore main screen buffer
    tput rmcup 2>/dev/null || true
    trap - SIGINT SIGTERM # Reset traps
}

show_container_dashboard() {
    local stop_dashboard=0
    trap 'stop_dashboard=1' SIGINT SIGTERM
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"
    clear

    while [ $stop_dashboard -eq 0 ]; do
        if ! tput cup 0 0 2>/dev/null; then
            printf "\033[H"
        fi

        print_live_stats_header
        echo -e "${CYAN}═══ PER-CONTAINER STATUS ═══${NC}\033[K"

        if [ "$CONTAINER_COUNT" -lt 1 ]; then
            echo -e "${YELLOW}No containers configured.${NC}\033[K"
        else
            for i in $(seq 1 "$CONTAINER_COUNT"); do
                local name=$(get_container_name "$i")
                local port_note=""
                if [ "$OS_FAMILY" = "macos" ]; then
                    port_note=" (port $(get_container_port "$i"))"
                fi
                if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
                    local logs=$(docker logs --tail 200 "$name" 2>&1 | grep "\[STATS\]" | tail -1)
                    local connecting=0
                    local connected=0
                    local upload=""
                    local download=""
                    local uptime=""
                    if [ -n "$logs" ]; then
                        connecting=$(echo "$logs" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p')
                        connected=$(echo "$logs" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
                        upload=$(echo "$logs" | sed -n 's/.*Up:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
                        download=$(echo "$logs" | sed -n 's/.*Down:[[:space:]]*\([^|]*\).*/\1/p' | xargs)
                        uptime=$(echo "$logs" | sed -n 's/.*Uptime:[[:space:]]*\(.*\)/\1/p' | xargs)
                    fi
                    connecting=${connecting:-0}
                    connected=${connected:-0}
                    local stats=$(get_container_stats "$name")
                    local app_cpu=$(echo "$stats" | awk '{print $1}')
                    local app_ram=$(echo "$stats" | awk '{print $2, $3, $4}')

                    echo -e "${GREEN}${name}${NC}${port_note} - ${GREEN}Running${NC}\033[K"
                    echo -e "  Clients: ${GREEN}${connected}${NC} connected, ${YELLOW}${connecting}${NC} connecting\033[K"
                    [ -n "$upload" ] && echo -e "  Upload: ${CYAN}${upload}${NC}  Download: ${CYAN}${download}${NC}\033[K"
                    [ -n "$uptime" ] && echo -e "  Uptime: ${CYAN}${uptime}${NC}\033[K"
                    echo -e "  CPU: ${YELLOW}${app_cpu}${NC}  RAM: ${YELLOW}${app_ram}${NC}\033[K"
                else
                    echo -e "${YELLOW}${name}${NC}${port_note} - ${RED}Stopped${NC}\033[K"
                fi
                echo -e "\033[K"
            done
        fi

        echo -e "${BOLD}Refreshes every 5 seconds. Press any key to return...${NC}\033[K"
        if ! tput ed 2>/dev/null; then
            printf "\033[J"
        fi

        # Wait for keypress with multiple short intervals for better responsiveness
        local waited=0
        while [ $waited -lt 25 ] && [ $stop_dashboard -eq 0 ]; do
            if read -t 0.2 -n 1 -s <> /dev/tty 2>/dev/null; then
                stop_dashboard=1
                break
            fi
            waited=$((waited + 1))
        done
    done

    echo -ne "\033[?25h"
    tput rmcup 2>/dev/null || true
    trap - SIGINT SIGTERM
}

get_container_stats() {
    # Get CPU and RAM usage for conduit container
    # Returns: "CPU_PERCENT RAM_USAGE"
    local name="${1:-conduit}"
    local stats=$(docker stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" "$name" 2>/dev/null)
    if [ -z "$stats" ]; then
        echo "0% 0MiB"
    else
        # Extract just the raw numbers/units, simpler format
        echo "$stats"
    fi
}

get_cpu_cores() {
    local cores=1
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
    elif command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c ^processor /proc/cpuinfo)
    fi
    if [ -z "$cores" ] || [ "$cores" -lt 1 ] 2>/dev/null; then echo 1; else echo "$cores"; fi
}

get_system_stats() {
    # Get System CPU (Live Delta) and RAM
    # Returns: "CPU_PERCENT RAM_USED RAM_TOTAL RAM_PCT"
    
    # 1. System CPU (Stateful Average)
    local sys_cpu="0%"
    local cpu_tmp="/tmp/conduit_cpu_state"
    
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        local cpu_line cpu_user cpu_sys cpu_usage
        cpu_line=$(top -l 2 -n 0 2>/dev/null | awk -F'CPU usage:' 'NF>1{print $2}' | tail -1)
        cpu_user=$(echo "$cpu_line" | sed -n 's/.*\([0-9.]*\)% user.*/\1/p')
        cpu_sys=$(echo "$cpu_line" | sed -n 's/.*\([0-9.]*\)% sys.*/\1/p')
        if [[ "$cpu_user" =~ ^[0-9.]+$ ]] && [[ "$cpu_sys" =~ ^[0-9.]+$ ]]; then
            cpu_usage=$(awk -v u="$cpu_user" -v s="$cpu_sys" 'BEGIN { printf "%.1f", u + s }')
            sys_cpu="${cpu_usage}%"
        else
            local ps_sum=""
            ps_sum=$(ps -A -o %cpu= 2>/dev/null | awk '{sum+=$1} END{if(sum>0) printf "%.1f", sum; else print ""}')
            if [[ "$ps_sum" =~ ^[0-9.]+$ ]]; then
                local cores=$(get_cpu_cores)
                cpu_usage=$(awk -v s="$ps_sum" -v c="$cores" 'BEGIN { if(c>0) printf "%.1f", s/c; else print s }')
                sys_cpu="${cpu_usage}%"
            else
                sys_cpu="N/A"
            fi
        fi
    elif [ -f /proc/stat ]; then
        read -r cpu user nice system idle iowait irq softirq steal guest < /proc/stat
        local total_curr=$((user + nice + system + idle + iowait + irq + softirq + steal))
        local work_curr=$((user + nice + system + irq + softirq + steal))
        
        if [ -f "$cpu_tmp" ]; then
            read -r total_prev work_prev < "$cpu_tmp"
            local total_delta=$((total_curr - total_prev))
            local work_delta=$((work_curr - work_prev))
            
            if [ "$total_delta" -gt 0 ]; then
                local cpu_usage=$(awk -v w="$work_delta" -v t="$total_delta" 'BEGIN { printf "%.1f", w * 100 / t }' 2>/dev/null || echo 0)
                sys_cpu="${cpu_usage}%"
            fi
        else
            sys_cpu="Calc..." # First run calibration
        fi
        
        # Save current state for next run
        echo "$total_curr $work_curr" > "$cpu_tmp"
    else
        sys_cpu="N/A"
    fi
    
    # 2. System RAM (Used, Total, Percentage)
    local sys_ram_used="N/A"
    local sys_ram_total="N/A"
    local sys_ram_pct="N/A"
    
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        local total_bytes
        total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "")
        local page_size
        page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "")
        local free_pages=""
        if [ -n "$total_bytes" ] && [ -n "$page_size" ]; then
            free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$(NF)); print $(NF)}')
        fi
        if [ -n "$total_bytes" ] && [ -n "$page_size" ] && [ -n "$free_pages" ]; then
            local free_bytes=$((free_pages * page_size))
            local used_bytes=$((total_bytes - free_bytes))
            if [ "$used_bytes" -lt 0 ] 2>/dev/null; then
                used_bytes=0
            fi
            sys_ram_used=$(format_bytes_compact "$used_bytes")
            sys_ram_total=$(format_bytes_compact "$total_bytes")
            sys_ram_pct=$(awk -v u="$used_bytes" -v t="$total_bytes" 'BEGIN { if (t>0) printf "%.1f%%", (u*100)/t; else print "N/A" }')
        fi
    elif command -v free &>/dev/null; then
        # Output: used total percentage
        local ram_data=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%s %s %.2f%%", $3, $2, ($3/$2)*100}')
        local ram_human=$(free -h 2>/dev/null | awk '/^Mem:/{print $3 " " $2}')
        
        sys_ram_used=$(echo "$ram_human" | awk '{print $1}')
        sys_ram_total=$(echo "$ram_human" | awk '{print $2}')
        sys_ram_pct=$(echo "$ram_data" | awk '{print $3}')
    fi
    
    echo "$sys_cpu $sys_ram_used $sys_ram_total $sys_ram_pct"
}

show_live_stats() {
    # Check if container is running first
    if ! docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        print_header
        echo -e "${RED}Conduit is not running!${NC}"
        echo "Start it first with option 6 or 'conduit start'"
        read -n 1 -s -r -p "Press any key to continue..." < /dev/tty 2>/dev/null || true
        return 1
    fi

    echo -e "${CYAN}Streaming live statistics... Press Ctrl+C to return to menu${NC}"
    echo -e "${YELLOW}(showing live logs filtered for [STATS])${NC}"
    echo ""

    # Trap Ctrl+C to allow handled exit from the log stream
    trap 'echo -e "\n${CYAN}Returning to menu...${NC}"; return' SIGINT

    # Stream logs and filter for [STATS]
    # We check if grep supports --line-buffered for smoother output, fallback to standard grep
    if grep --help 2>&1 | grep -q -- --line-buffered; then
        docker logs -f --tail 20 conduit 2>&1 | grep --line-buffered "\[STATS\]"
    else
        docker logs -f --tail 20 conduit 2>&1 | grep "\[STATS\]"
    fi

    # Reset trap
    trap - SIGINT
}

# format_bytes() - Convert bytes to human-readable format (B, KB, MB, GB)
format_bytes() {
    local bytes=$1

    # Handle empty or zero input
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0 B"
        return
    fi

    # Convert based on size thresholds (using binary units)
    # 1 GB = 1073741824 bytes (1024^3)
    # 1 MB = 1048576 bytes (1024^2)
    # 1 KB = 1024 bytes
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.2f KB\", $bytes/1024}"
    else
        echo "$bytes B"
    fi
}

format_bytes_compact() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0B"
        return
    fi
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.2fGiB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2fMiB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.2fKiB\", $bytes/1024}"
    else
        echo "${bytes}B"
    fi
}

# show_peers_macos() - macOS version using tracker data instead of tcpdump
show_peers_macos() {
    local stop_peers=0
    trap 'stop_peers=1' SIGINT SIGTERM
    
    local persist_dir="$INSTALL_DIR/traffic_stats"
    
    # Check if tracker is running and has data
    if [ ! -f "$persist_dir/tracker_snapshot" ] || [ ! -f "$persist_dir/cumulative_data" ]; then
        clear
        print_header
        echo -e "${YELLOW}═══ LIVE PEER MAP ═══${NC}"
        echo ""
        echo -e "${RED}Tracker data not available.${NC}"
        echo -e "Make sure the tracker is enabled and running (press 'd' from main menu)."
        echo ""
        read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
        return 1
    fi
    
    # Enter alternate screen buffer
    tput smcup 2>/dev/null || true
    echo -ne "\033[?25l"  # Hide cursor
    
    local last_refresh=0
    
    while [ $stop_peers -eq 0 ]; do
        local now=$(date +%s)
        local elapsed=$((now - last_refresh))
        
        # Only refresh data every 5 seconds
        if [ $last_refresh -eq 0 ] || [ $elapsed -ge 5 ]; then
            last_refresh=$now
            
            clear
            printf "\033[H"
            
            # Header
            local update_time=$(date '+%H:%M:%S')
            echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${CYAN}║${NC}  LIVE PEER TRAFFIC BY COUNTRY                     [q] Back"
            echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════╣${NC}"
            printf "${CYAN}║${NC} Last Update: %-42s ${GREEN}[LIVE]${NC}\n" "$update_time"
            echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            
            # Read tracker data
            local snapshot_file="$persist_dir/tracker_snapshot"
            local cumulative_file="$persist_dir/cumulative_data"
            
            if [ -s "$snapshot_file" ] && [ -s "$cumulative_file" ]; then
            # Get ACTIVE clients per country from Docker /proc/net/tcp (real-time)
            declare -A country_clients
            local temp_active="/tmp/active_ips_$$.tmp"
            > "$temp_active"
            
            # Extract currently active IPs from all containers
            for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
                local cname="conduit"
                [ $i -gt 1 ] && cname="conduit-$i"
                
                docker exec "$cname" cat /proc/net/tcp 2>/dev/null | tail -n +2 | while read line; do
                    local rem_addr=$(echo "$line" | awk '{print $3}')
                    local rem_ip_hex=$(echo "$rem_addr" | cut -d':' -f1)
                    [ ${#rem_ip_hex} -ne 8 ] && continue
                    
                    # Convert hex to IP
                    local ip=$(printf "%d.%d.%d.%d" 0x${rem_ip_hex:6:2} 0x${rem_ip_hex:4:2} 0x${rem_ip_hex:2:2} 0x${rem_ip_hex:0:2})
                    echo "$ip" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)' && continue
                    echo "$ip"
                done >> "$temp_active"
            done
            
            # Count unique active IPs per country using GeoIP
            sort -u "$temp_active" | while read -r ip; do
                [ -z "$ip" ] && continue
                local country="Unknown"
                
                # GeoIP lookup
                if command -v mmdblookup >/dev/null 2>&1; then
                    local mmdb_path=""
                    for db in "$INSTALL_DIR/geoip/dbip-country-lite.mmdb" \
                              "$INSTALL_DIR/geoip/GeoLite2-Country.mmdb" \
                              "/usr/local/share/GeoIP/dbip-country-lite.mmdb"; do
                        if [ -f "$db" ]; then
                            mmdb_path="$db"
                            break
                        fi
                    done
                    if [ -n "$mmdb_path" ]; then
                        country=$(mmdblookup --file "$mmdb_path" --ip "$ip" country names en 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | head -1)
                    fi
                fi
                [ -z "$country" ] && country="Unknown"
                echo "$country"
            done | sort | uniq -c | while read count country; do
                echo "${country}|${count}"
            done > "${temp_active}.counts"
            
            # Load active client counts
            while IFS='|' read -r country count; do
                country_clients["$country"]=$count
            done < "${temp_active}.counts"
            rm -f "$temp_active" "${temp_active}.counts"
            
            # Read cumulative traffic per country
            declare -A country_down country_up
            while IFS='|' read -r country down up; do
                [ -z "$country" ] && continue
                country_down["$country"]=$down
                country_up["$country"]=$up
            done < "$cumulative_file"
            
            # Display TOP 10 TRAFFIC FROM (Download)
            echo -e " ${GREEN}${BOLD}📥 TOP 10 TRAFFIC FROM (peers connecting to you)${NC}"
            echo ""
            printf " ${BOLD}%-35s${NC}  ${GREEN}${BOLD}%12s${NC}   %-12s\n" "Country" "Total" "Clients"
            echo " ─────────────────────────────────────────────────────────────────────────"
            
            # Sort by download (from)
            for country in "${!country_down[@]}"; do
                echo "${country}|${country_down[$country]}|${country_clients[$country]:-0}"
            done | sort -t'|' -k2 -rn | head -10 | while IFS='|' read -r country down clients; do
                local down_fmt=$(format_bytes "$down")
                printf " ${CYAN}%-35s${NC}  ${GREEN}${BOLD}%12s${NC}   %-12s\n" "$country" "$down_fmt" "$clients"
            done
            
            echo ""
            echo ""
            
            # Display TOP 10 TRAFFIC TO (Upload)
            echo -e " ${YELLOW}${BOLD}📤 TOP 10 TRAFFIC TO (data sent to peers)${NC}"
            echo ""
            printf " ${BOLD}%-35s${NC}  ${YELLOW}${BOLD}%12s${NC}   %-12s\n" "Country" "Total" "Clients"
            echo " ─────────────────────────────────────────────────────────────────────────"
            
            # Sort by upload (to)
            for country in "${!country_up[@]}"; do
                echo "${country}|${country_up[$country]}|${country_clients[$country]:-0}"
            done | sort -t'|' -k2 -rn | head -10 | while IFS='|' read -r country up clients; do
                local up_fmt=$(format_bytes "$up")
                printf " ${CYAN}%-35s${NC}  ${YELLOW}${BOLD}%12s${NC}   %-12s\n" "$country" "$up_fmt" "$clients"
            done
        else
            echo -e "   ${YELLOW}Waiting for tracker data...${NC}"
            for i in {1..20}; do echo ""; done
        fi
        
        # Add empty lines to match Linux layout
        echo ""
        for i in {1..11}; do echo ""; done
        fi
        
        # Continuously update progress bar until next refresh
        while true; do
            local now=$(date +%s)
            local time_left=$((5 - (now - last_refresh)))
            
            # Time for next refresh?
            if [ $time_left -le 0 ]; then
                break
            fi
            
            # Draw progress bar
            local filled=$((5 - time_left))
            echo -ne "\r["
            for ((i=0; i<filled; i++)); do echo -n "●"; done
            for ((i=filled; i<5; i++)); do echo -n "○"; done
            echo -ne "] Next refresh in ${time_left}s  [q] Back   "
            
            # Check for user input (non-blocking, 200ms wait)
            if read -t 0.2 -n 1 -s key <> /dev/tty 2>/dev/null; then
                [ "$key" = "q" ] || [ "$key" = "Q" ] && stop_peers=1
                break
            fi
        done
        
        [ $stop_peers -eq 1 ] && break
    done
    
    # Cleanup
    echo -ne "\033[?25h"  # Show cursor
    tput rmcup 2>/dev/null || true
    return 0
}

# show_peers() - Live peer traffic by country using Docker /proc/net/tcp + GeoIP
# Works without sudo on macOS
show_peers() {
    local is_darwin=0
    [ "$(uname -s 2>/dev/null)" = "Darwin" ] && is_darwin=1

    # On macOS, use tracker data instead of tcpdump
    if [ $is_darwin -eq 1 ]; then
        show_peers_macos
        return $?
    fi

    # Linux version continues with tcpdump-based live map
    # Flag to control the main loop - set to 1 on user interrupt
    local stop_peers=0
    trap 'stop_peers=1' SIGINT SIGTERM

    # GeoIP backend: require either geoiplookup (Linux) or mmdblookup+DB (macOS)
    if ! command -v geoiplookup &>/dev/null; then
        if [ $is_darwin -eq 1 ]; then
            local mmdb_bin mmdb_path
            mmdb_bin="$(find_mmdblookup)"
            mmdb_path="$(resolve_geoip_db)"
            if [ -z "$mmdb_bin" ] || [ -z "$mmdb_path" ] || [ ! -f "$mmdb_path" ]; then
                echo -e "${RED}Error: GeoIP database not configured.${NC}"
                echo "Re-run the installer to set up DB-IP Lite database, then try again."
                echo ""
                geoip_diag
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                return 1
            fi
        else
            echo -e "${RED}Error: geoiplookup not found!${NC}"
            echo "Please re-run the main installer to fix dependencies."
            read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
            return 1
        fi
    fi

    # Network interface detection
    local iface="any"

    # Detect local IP address to determine traffic direction
    local local_ip=""
    if [ $is_darwin -eq 1 ]; then
        iface="$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2; exit}')"
        [ -z "$iface" ] && iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
        [ -z "$iface" ] && iface="en0"
        local_ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    else
        # Linux
        local_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
        [ -z "$local_ip" ] && local_ip=$(hostname -I | awk '{print $1}')
    fi

    # On macOS, print GeoIP diagnostic once up-front
    if [ $is_darwin -eq 1 ]; then
        geoip_diag
    fi

    # Clean temporary working files (per-cycle data only)
    rm -f /tmp/conduit_peers_current /tmp/conduit_peers_raw
    rm -f /tmp/conduit_traffic_from /tmp/conduit_traffic_to
    touch /tmp/conduit_traffic_from /tmp/conduit_traffic_to

    # Persistent data directory - survives across option 9 sessions
    local persist_dir="$INSTALL_DIR/traffic_stats"
    mkdir -p "$persist_dir"

    # Get container start time to detect restarts
    local container_start=$(docker inspect --format='{{.State.StartedAt}}' conduit 2>/dev/null | cut -d'.' -f1)
    local stored_start=""
    [ -f "$persist_dir/container_start" ] && stored_start=$(cat "$persist_dir/container_start")

    # If container was restarted, reset all cumulative data
    if [ "$container_start" != "$stored_start" ]; then
        echo "$container_start" > "$persist_dir/container_start"
        rm -f "$persist_dir/cumulative_data" "$persist_dir/cumulative_ips" "$persist_dir/session_start"
    fi

    # Cumulative data files persist until Conduit restarts
    # Format: Country|TotalFrom|TotalTo (bytes received from / sent to)
    [ ! -f "$persist_dir/cumulative_data" ] && touch "$persist_dir/cumulative_data"
    # Format: Country|IP (one line per unique IP seen)
    [ ! -f "$persist_dir/cumulative_ips" ] && touch "$persist_dir/cumulative_ips"

    # Session start time - when we first started tracking (persists until Conduit restart)
    if [ ! -f "$persist_dir/session_start" ]; then
        date +%s > "$persist_dir/session_start"
    fi
    local session_start=$(cat "$persist_dir/session_start")

    # Enter alternate screen buffer (preserves terminal history)
    tput smcup 2>/dev/null || true
    # Hide cursor for cleaner display
    echo -ne "\033[?25l"

    #═══════════════════════════════════════════════════════════════════
    # Main display loop - runs until user presses a key
    #═══════════════════════════════════════════════════════════════════
    while [ $stop_peers -eq 0 ]; do
        # Clear screen completely and move to top-left
        clear
        printf "\033[H"

        #───────────────────────────────────────────────────────────────
        # Header Section - Compact title bar with live status indicator
        # Shows: Title, session duration, and [LIVE - last 15s] indicator
        #───────────────────────────────────────────────────────────────
        # Calculate how long this view session has been running
        local now=$(date +%s)
        local duration=$((now - session_start))
        local dur_min=$((duration / 60))
        local dur_sec=$((duration % 60))
        local duration_str=$(printf "%02d:%02d" $dur_min $dur_sec)

        local inner_width=67
        local title="LIVE PEER TRAFFIC BY COUNTRY"
        local title_len=${#title}
        local pad_total=$((inner_width - title_len))
        [ "$pad_total" -lt 0 ] && pad_total=0
        local pad_left=$((pad_total / 2))
        local pad_right=$((pad_total - pad_left))

        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
        printf "${CYAN}║%*s%s%*s║${NC}\n" "$pad_left" "" "$title" "$pad_right" ""
        echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
        if [ -f /tmp/conduit_peers_current ]; then
            # Data is available - show last update time
            local update_time=$(date '+%H:%M:%S')
            local left_raw="Last Update: ${update_time}"
            local right_raw="[LIVE]"
            local left_pad
            local right_pad
            left_pad=$(printf "%-56s" "$left_raw")
            right_pad=$(printf "%7s" "$right_raw")
            printf "%b║  %b%s%b %b%s%b %b║%b\n" "$CYAN" "" "$left_pad" "$NC" "$GREEN" "$right_pad" "$NC" "$CYAN" "$NC"
        else
            # Waiting for first data capture
            local left_raw="Status: Initializing..."
            local right_raw=""
            local left_pad
            local right_pad
            left_pad=$(printf "%-56s" "$left_raw")
            right_pad=$(printf "%7s" "$right_raw")
            printf "%b║  %b%s%b %b%s%b %b║%b\n" "$CYAN" "$YELLOW" "$left_pad" "$NC" "" "$right_pad" "$NC" "$CYAN" "$NC"
        fi
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
        echo -e ""

        #───────────────────────────────────────────────────────────────
        # Data Tables - Display TOP 10 countries by traffic volume
        #
        # "TRAFFIC FROM" = Data received from that country (incoming)
        #                  These are peers connecting TO your Conduit node
        # "TRAFFIC TO"   = Data sent to that country (outgoing)
        #                  This is data your node sends back to peers
        #
        # Columns explained:
        #   Total    = Cumulative bytes since this view started
        #   Speed    = Current transfer rate (from last 15-second window)
        #   IPs      = Unique IP addresses (Total seen / Currently active)
        #
        # Colors: GREEN = incoming traffic, YELLOW = outgoing traffic
        #         #FreeIran = RED (solidarity highlight)
        #───────────────────────────────────────────────────────────────
        if [ -s /tmp/conduit_traffic_from ]; then
            # Section 1: Top 10 countries by incoming traffic (data FROM them)
            # This shows which countries have peers connecting to your node
            echo -e "${GREEN}${BOLD}   📥 TOP 10 TRAFFIC FROM (peers connecting to you)${NC}"
            echo -e "   ─────────────────────────────────────────────────────────────────────────"
            printf "   ${BOLD}%-26s${NC}  ${GREEN}${BOLD}%10s   %12s${NC}   %-12s\n" "Country" "Total" "Speed" "IPs (all/now)"
            echo -e "   ─────────────────────────────────────────────────────────────────────────"
            # Read top 10 entries from incoming-traffic-sorted file
            head -10 /tmp/conduit_traffic_from | while read -r line; do
                # Parse pipe-delimited fields: Country|TotalFrom|TotalTo|SpeedFrom|SpeedTo|TotalIPs|ActiveIPs
                local country=$(echo "$line" | cut -d'|' -f1)
                local from_bytes=$(echo "$line" | cut -d'|' -f2)
                local from_speed=$(echo "$line" | cut -d'|' -f4)
                local total_ips=$(echo "$line" | cut -d'|' -f6)
                local active_ips=$(echo "$line" | cut -d'|' -f7)
                # Format bytes to human-readable (KB/MB/GB)
                local from_fmt=$(format_bytes "$from_bytes")
                local from_spd_fmt=$(format_bytes "$from_speed")/s
                # Format IP counts - handle empty values
                [ -z "$total_ips" ] && total_ips="0"
                [ -z "$active_ips" ] && active_ips="0"
                local ip_display="${total_ips}/${active_ips}"
                # Print row: CYAN country, GREEN values (Total/Speed right-aligned, IPs left-aligned)
                printf "   ${CYAN}%-26s${NC}  ${GREEN}${BOLD}%10s   %12s${NC}   %-12s\n" "$country" "$from_fmt" "$from_spd_fmt" "$ip_display"
            done
            echo ""

            # Section 2: Top 10 countries by outgoing traffic (data TO them)
            # This shows which countries you're sending the most data to
            echo -e "${YELLOW}${BOLD}   📤 TOP 10 TRAFFIC TO (data sent to peers)${NC}"
            echo -e "   ─────────────────────────────────────────────────────────────────────────"
            printf "   ${BOLD}%-26s${NC}  ${YELLOW}${BOLD}%10s   %12s${NC}   %-12s\n" "Country" "Total" "Speed" "IPs (all/now)"
            echo -e "   ─────────────────────────────────────────────────────────────────────────"
            # Read top 10 entries from outgoing-traffic-sorted file
            head -10 /tmp/conduit_traffic_to | while read -r line; do
                # Parse pipe-delimited fields: Country|TotalFrom|TotalTo|SpeedFrom|SpeedTo|TotalIPs|ActiveIPs
                local country=$(echo "$line" | cut -d'|' -f1)
                local to_bytes=$(echo "$line" | cut -d'|' -f3)
                local to_speed=$(echo "$line" | cut -d'|' -f5)
                local total_ips=$(echo "$line" | cut -d'|' -f6)
                local active_ips=$(echo "$line" | cut -d'|' -f7)
                # Format bytes to human-readable (KB/MB/GB)
                local to_fmt=$(format_bytes "$to_bytes")
                local to_spd_fmt=$(format_bytes "$to_speed")/s
                # Format IP counts - handle empty values
                [ -z "$total_ips" ] && total_ips="0"
                [ -z "$active_ips" ] && active_ips="0"
                local ip_display="${total_ips}/${active_ips}"
                # Print row: CYAN country, YELLOW values (Total/Speed right-aligned, IPs left-aligned)
                printf "   ${CYAN}%-26s${NC}  ${YELLOW}${BOLD}%10s   %12s${NC}   %-12s\n" "$country" "$to_fmt" "$to_spd_fmt" "$ip_display"
            done
        else
            # No data yet - show waiting message with padding
            echo -e "   ${YELLOW}Waiting for first snapshot... (High traffic helps speed this up)${NC}"
            for i in {1..20}; do echo ""; done
        fi

        echo -e ""
        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"

        #═══════════════════════════════════════════════════════════════════
        # Background Traffic Capture
        #═══════════════════════════════════════════════════════════════════
        # Uses tcpdump to capture live network packets for 15 seconds
        # tcpdump flags:
        #   -n  : Don't resolve hostnames (faster)
        #   -i  : Interface to capture on ("any" = all interfaces)
        #   -q  : Quiet output (less verbose)
        #
        # The captured output is piped to awk which:
        #   1. Extracts source and destination IP addresses
        #   2. Extracts packet length from each line
        #   3. Filters out private/local IP ranges (RFC 1918)
        #   4. Determines traffic direction (from vs to)
        #   5. Aggregates bytes per IP address
        #   6. Outputs: IP|bytes_from_remote|bytes_to_remote
        #
        # Traffic direction naming (from your server's perspective):
        #   "from" = bytes received FROM remote IP (remote -> local)
        #   "to"   = bytes sent TO remote IP (local -> remote)
        #═══════════════════════════════════════════════════════════════════
        # Wrap pipeline in subshell so $! captures the whole pipeline PID, not just awk
        # This ensures the progress indicator runs for the full 15-second capture
        (
            run_with_timeout 15 tcpdump -ni $iface -q '(tcp or udp)' 2>/dev/null | \
            awk -v local_ip="$local_ip" '
            # Portable awk script - works with mawk, gawk, and busybox awk
            /IP/ {
                # Parse tcpdump output to extract IPs and packet length
                # Example format: "IP 192.168.1.1.443 > 8.8.8.8.12345: TCP, length 1460"
                # Or: "IP 10.0.0.1.22 > 203.0.113.5.54321: UDP, length 64"

                src = ""
                dst = ""
                len = 0

                # Find the field containing "IP" and extract source/dest
                for (i = 1; i <= NF; i++) {
                    if ($i == "IP") {
                        # Next field is source IP.port
                        src_field = $(i+1)
                        # Field after ">" is dest IP.port
                        for (j = i+2; j <= NF; j++) {
                            if ($(j-1) == ">") {
                                dst_field = $j
                                # Remove trailing colon if present
                                gsub(/:$/, "", dst_field)
                                break
                            }
                        }
                        break
                    }
                }

                # Extract IP from IP.port format (remove last .port segment)
                # Example: 192.168.1.1.443 -> 192.168.1.1
                if (src_field != "") {
                    n = split(src_field, parts, ".")
                    if (n >= 4) {
                        src = parts[1] "." parts[2] "." parts[3] "." parts[4]
                    }
                }
                if (dst_field != "") {
                    n = split(dst_field, parts, ".")
                    if (n >= 4) {
                        dst = parts[1] "." parts[2] "." parts[3] "." parts[4]
                    }
                }

                # Extract packet length - look for "length N" pattern
                for (i = 1; i <= NF; i++) {
                    if ($i == "length") {
                        len = $(i+1) + 0
                        break
                    }
                }
                # Fallback: use last numeric field if no "length" found
                if (len == 0) {
                    for (i = NF; i > 0; i--) {
                        if ($i ~ /^[0-9]+$/) {
                            len = $i + 0
                            break
                        }
                    }
                }

                # Skip if we could not parse IPs
                if (src == "" && dst == "") next

                # Filter out private/reserved IP ranges (RFC 1918 + others)
                # 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8,
                # 0.0.0.0/8, 169.254.0.0/16 (link-local)
                if (src ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.|169\.254\.)/) src = ""
                if (dst ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.|169\.254\.)/) dst = ""

                # Determine traffic direction based on local IP
                # "traffic_from" = bytes coming FROM remote (incoming to your server)
                # "traffic_to"   = bytes going TO remote (outgoing from your server)
                if (src == local_ip && dst != "" && dst != local_ip) {
                    # Outgoing: packet going FROM local TO remote
                    traffic_to[dst] += len
                    ips[dst] = 1
                } else if (dst == local_ip && src != "" && src != local_ip) {
                    # Incoming: packet coming FROM remote TO local
                    traffic_from[src] += len
                    ips[src] = 1
                } else if (src != "" && src != local_ip) {
                    # Fallback: non-local source = incoming traffic
                    traffic_from[src] += len
                    ips[src] = 1
                } else if (dst != "" && dst != local_ip) {
                    # Fallback: non-local destination = outgoing traffic
                    traffic_to[dst] += len
                    ips[dst] = 1
                }
            }
            END {
                # Output aggregated data: IP|bytes_from|bytes_to
                for (ip in ips) {
                    from_bytes = traffic_from[ip] + 0  # Default to 0 if undefined
                    to_bytes = traffic_to[ip] + 0
                    print ip "|" from_bytes "|" to_bytes
                }
            }' > /tmp/conduit_peers_raw
        ) 2>/dev/null &

        # Store subshell PID for cleanup if user exits early
        local tcpdump_pid=$!

        #───────────────────────────────────────────────────────────────
        # Progress Indicator Loop - runs for exactly 15 seconds
        # Shows animated dots while tcpdump captures data
        # Checks for user keypress every second to allow early exit
        #───────────────────────────────────────────────────────────────
        local count=0
        while [ $count -lt 15 ]; do
            if read -t 1 -n 1 -s <> /dev/tty 2>/dev/null; then
                stop_peers=1
                kill $tcpdump_pid 2>/dev/null
                break
            fi
            count=$((count + 1))
            echo -ne "\r  [${YELLOW}"
            for ((i=0; i<count; i++)); do echo -n "•"; done
            for ((i=count; i<15; i++)); do echo -n " "; done
            echo -ne "${NC}] Capturing next update... (Any key to exit) \033[K"
        done

        # Wait for tcpdump to finish (should already be done after 15s)
        wait $tcpdump_pid 2>/dev/null

        # Exit loop if user requested stop
        if [ $stop_peers -eq 1 ]; then break; fi

        #═══════════════════════════════════════════════════════════════════
        # GeoIP Resolution and Country Aggregation (Cumulative)
        #═══════════════════════════════════════════════════════════════════
        # Process the raw IP data:
        #   1. Read each IP with its from/to bytes from this cycle
        #   2. Resolve IP to country using geoiplookup
        #   3. Add to cumulative totals (persisted in temp file)
        #   4. Track unique IPs per country (cumulative and active)
        #   5. Calculate bandwidth speed (bytes per second from 15s window)
        #   6. Create sorted output files for display
        #
        # Traffic direction naming:
        #   "from" = bytes received FROM remote IP (incoming to your server)
        #   "to"   = bytes sent TO remote IP (outgoing from your server)
        #═══════════════════════════════════════════════════════════════════
        if [ -s /tmp/conduit_peers_raw ]; then
            # Associative arrays for this capture cycle - MUST unset first!
            # In bash, 'declare -A' does NOT clear existing arrays, causing accumulation bug
            unset cycle_from cycle_to cycle_ips ip_to_country
            declare -A cycle_from       # Bytes received FROM each country this cycle
            declare -A cycle_to         # Bytes sent TO each country this cycle
            declare -A cycle_ips        # IPs seen this cycle per country (for active count)
            declare -A ip_to_country    # Map IP -> country for deduplication

            # Process each IP from the raw capture data
            # Raw format: IP|bytes_from|bytes_to
            while IFS='|' read -r ip from_bytes to_bytes; do
                [ -z "$ip" ] && continue

                # Resolve IP to country using GeoIP database
                local country_info=$(geoip_lookup_country "$ip")
                [ -z "$country_info" ] && country_info="Unknown"

                # Normalize certain country names for display
                country_info=$(echo "$country_info" | sed 's/Iran, Islamic Republic of/Iran - #FreeIran/' | sed 's/Moldova, Republic of/Moldova/')

                # Store IP to country mapping for later
                ip_to_country["$ip"]="$country_info"

                # Aggregate this cycle's traffic by country
                cycle_from["$country_info"]=$((${cycle_from["$country_info"]:-0} + from_bytes))
                cycle_to["$country_info"]=$((${cycle_to["$country_info"]:-0} + to_bytes))

                # Track active IPs this cycle (append IP to country's IP list)
                cycle_ips["$country_info"]="${cycle_ips["$country_info"]} $ip"
            done < /tmp/conduit_peers_raw

            # Load existing cumulative traffic data from persistent storage
            unset cumul_from cumul_to
            declare -A cumul_from
            declare -A cumul_to
            if [ -s "$persist_dir/cumulative_data" ]; then
                while IFS='|' read -r country cfrom cto; do
                    [ -z "$country" ] && continue
                    cumul_from["$country"]=$cfrom
                    cumul_to["$country"]=$cto
                done < "$persist_dir/cumulative_data"
            fi

            # Add this cycle's traffic to cumulative totals
            for country in "${!cycle_from[@]}"; do
                cumul_from["$country"]=$((${cumul_from["$country"]:-0} + ${cycle_from["$country"]}))
                cumul_to["$country"]=$((${cumul_to["$country"]:-0} + ${cycle_to["$country"]}))
            done

            # Save updated cumulative traffic data to persistent storage
            > "$persist_dir/cumulative_data"
            for country in "${!cumul_from[@]}"; do
                echo "${country}|${cumul_from[$country]}|${cumul_to[$country]}" >> "$persist_dir/cumulative_data"
            done
            
            # Fix ownership if running as root (preserve user ownership for tracker)
            if [ "$EUID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
                chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$persist_dir/cumulative_data" 2>/dev/null || true
            fi

            # Update cumulative IP tracking (add new IPs seen this cycle)
            for ip in "${!ip_to_country[@]}"; do
                local country="${ip_to_country[$ip]}"
                # Check if this IP|Country combo already exists
                if ! grep -q "^${country}|${ip}$" "$persist_dir/cumulative_ips" 2>/dev/null; then
                    echo "${country}|${ip}" >> "$persist_dir/cumulative_ips"
                fi
            done
            
            # Fix ownership if running as root (preserve user ownership for tracker)
            if [ "$EUID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
                chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$persist_dir/cumulative_ips" 2>/dev/null || true
            fi

            # Count total unique IPs per country (cumulative)
            unset total_ips_count
            declare -A total_ips_count
            if [ -s "$persist_dir/cumulative_ips" ]; then
                while IFS='|' read -r country ip; do
                    [ -z "$country" ] && continue
                    total_ips_count["$country"]=$((${total_ips_count["$country"]:-0} + 1))
                done < "$persist_dir/cumulative_ips"
            fi

            # Count active IPs this cycle per country
            unset active_ips_count
            declare -A active_ips_count
            for country in "${!cycle_ips[@]}"; do
                # Count unique IPs in this cycle's IP list for this country
                local unique_count=$(echo "${cycle_ips[$country]}" | tr ' ' '\n' | sort -u | grep -c '.')
                active_ips_count["$country"]=$unique_count
            done

            # Generate sorted output with all metrics
            # Format: Country|TotalFrom|TotalTo|SpeedFrom|SpeedTo|TotalIPs|ActiveIPs
            > /tmp/conduit_traffic_from
            > /tmp/conduit_traffic_to
            for country in "${!cumul_from[@]}"; do
                local total_from=${cumul_from[$country]}
                local total_to=${cumul_to[$country]}
                local cycle_from_val=${cycle_from["$country"]:-0}
                local cycle_to_val=${cycle_to["$country"]:-0}
                # Calculate speed (bytes per second) from 15-second capture
                local speed_from=$((cycle_from_val / 15))
                local speed_to=$((cycle_to_val / 15))
                # Get IP counts
                local total_ips=${total_ips_count["$country"]:-0}
                local active_ips=${active_ips_count["$country"]:-0}
                echo "${country}|${total_from}|${total_to}|${speed_from}|${speed_to}|${total_ips}|${active_ips}" >> /tmp/conduit_traffic_from
            done

            # Sort by total incoming traffic (field 2) descending
            sort -t'|' -k2 -nr -o /tmp/conduit_traffic_from /tmp/conduit_traffic_from

            # Copy and sort by total outgoing traffic (field 3) descending
            cp /tmp/conduit_traffic_from /tmp/conduit_traffic_to
            sort -t'|' -k3 -nr -o /tmp/conduit_traffic_to /tmp/conduit_traffic_to

            # Touch marker file to indicate data is ready for display
            touch /tmp/conduit_peers_current
        fi

        echo -ne "\r  ${GREEN}✓ Update complete! Refreshing...${NC} \033[K"
        sleep 1
    done
    # End of main display loop

    #═══════════════════════════════════════════════════════════════════
    # Cleanup - restore terminal state and remove temp files
    # Note: Persistent data in /opt/conduit/traffic_stats/ is NOT removed
    #       It persists until Conduit container restarts
    #═══════════════════════════════════════════════════════════════════
    echo -ne "\033[?25h"  # Show cursor
    tput rmcup 2>/dev/null || true  # Exit alternate screen buffer
    # Remove only temporary working files (not persistent cumulative data)
    rm -f /tmp/conduit_peers_current /tmp/conduit_peers_raw
    rm -f /tmp/conduit_traffic_from /tmp/conduit_traffic_to
    trap - SIGINT SIGTERM  # Remove signal handlers
}

# Connection history file for tracking connections over time
_LAST_HISTORY_RECORD=0

# Peak connections tracking (persistent, resets on container restart)
_PEAK_CONNECTIONS=0
_PEAK_CONTAINER_START=""

# Get the earliest container start time (used to detect restarts)
get_container_start_time() {
    local earliest=""
    for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
        local cname=$(get_container_name $i 2>/dev/null)
        [ -z "$cname" ] && continue
        local start=$(docker inspect --format='{{.State.StartedAt}}' "$cname" 2>/dev/null | cut -d'.' -f1)
        [ -z "$start" ] && continue
        if [ -z "$earliest" ] || [[ "$start" < "$earliest" ]]; then
            earliest="$start"
        fi
    done
    echo "$earliest"
}

# Load peak from file (resets if containers restarted)
load_peak_connections() {
    local current_start=$(get_container_start_time)

    if [ -f "$PEAK_CONNECTIONS_FILE" ]; then
        local saved_start=$(head -1 "$PEAK_CONNECTIONS_FILE" 2>/dev/null)
        local saved_peak=$(tail -1 "$PEAK_CONNECTIONS_FILE" 2>/dev/null)

        if [ "$saved_start" = "$current_start" ] && [ -n "$saved_peak" ]; then
            _PEAK_CONNECTIONS=$saved_peak
            _PEAK_CONTAINER_START="$current_start"
            return
        fi
    fi

    _PEAK_CONNECTIONS=0
    _PEAK_CONTAINER_START="$current_start"
    save_peak_connections
}

# Save peak to file
save_peak_connections() {
    mkdir -p "$(dirname "$PEAK_CONNECTIONS_FILE")" 2>/dev/null
    echo "$_PEAK_CONTAINER_START" > "$PEAK_CONNECTIONS_FILE"
    echo "$_PEAK_CONNECTIONS" >> "$PEAK_CONNECTIONS_FILE"
    fix_file_ownership "$PEAK_CONNECTIONS_FILE"
}

# Connection history container tracking (resets when containers restart)
_CONNECTION_HISTORY_CONTAINER_START=""

# Check and reset connection history if containers restarted
check_connection_history_reset() {
    if [ -z "$CONNECTION_HISTORY_START_FILE" ]; then
        PERSIST_DIR="${PERSIST_DIR:-$INSTALL_DIR/traffic_stats}"
        CONNECTION_HISTORY_FILE="${CONNECTION_HISTORY_FILE:-$PERSIST_DIR/connection_history}"
        CONNECTION_HISTORY_START_FILE="${CONNECTION_HISTORY_START_FILE:-$PERSIST_DIR/connection_history_start}"
        PEAK_CONNECTIONS_FILE="${PEAK_CONNECTIONS_FILE:-$PERSIST_DIR/peak_connections}"
    fi
    local current_start=$(get_container_start_time)

    if [ -f "$CONNECTION_HISTORY_START_FILE" ]; then
        local saved_start=$(cat "$CONNECTION_HISTORY_START_FILE" 2>/dev/null)
        if [ "$saved_start" = "$current_start" ] && [ -n "$saved_start" ]; then
            _CONNECTION_HISTORY_CONTAINER_START="$current_start"
            return
        fi
    fi

    _CONNECTION_HISTORY_CONTAINER_START="$current_start"
    mkdir -p "$(dirname "$CONNECTION_HISTORY_START_FILE")" 2>/dev/null
    echo "$current_start" > "$CONNECTION_HISTORY_START_FILE"

    rm -f "$CONNECTION_HISTORY_FILE" 2>/dev/null
    _AVG_CONN_CACHE=""
    _AVG_CONN_CACHE_TIME=0
}

# Record current connection count to history (called every ~5 minutes)
record_connection_history() {
    local connected=$1
    local connecting=$2
    local now=$(date +%s)

    if [ $(( now - _LAST_HISTORY_RECORD )) -lt 300 ]; then
        return
    fi
    _LAST_HISTORY_RECORD=$now

    check_connection_history_reset

    mkdir -p "$(dirname "$CONNECTION_HISTORY_FILE")" 2>/dev/null
    echo "${now}|${connected}|${connecting}" >> "$CONNECTION_HISTORY_FILE"

    local cutoff=$((now - 90000))
    if [ -f "$CONNECTION_HISTORY_FILE" ]; then
        awk -F'|' -v cutoff="$cutoff" '$1 >= cutoff' "$CONNECTION_HISTORY_FILE" > "${CONNECTION_HISTORY_FILE}.tmp" 2>/dev/null
        mv -f "${CONNECTION_HISTORY_FILE}.tmp" "$CONNECTION_HISTORY_FILE" 2>/dev/null
        fix_file_ownership "$CONNECTION_HISTORY_FILE"
    fi
}

# Average connections cache (recalculate every 5 minutes)
_AVG_CONN_CACHE=""
_AVG_CONN_CACHE_TIME=0

# Get average connections since container started (cached for 5 min)
get_average_connections() {
    local now=$(date +%s)

    if [ -n "$_AVG_CONN_CACHE" ] && [ $((now - _AVG_CONN_CACHE_TIME)) -lt 300 ]; then
        echo "$_AVG_CONN_CACHE"
        return
    fi

    check_connection_history_reset

    if [ ! -f "$CONNECTION_HISTORY_FILE" ]; then
        _AVG_CONN_CACHE="-"
        _AVG_CONN_CACHE_TIME=$now
        echo "-"
        return
    fi

    local avg=$(awk -F'|' '
        NF >= 2 { sum += $2; count++ }
        END { if (count > 0) printf "%.0f", sum/count; else print "-" }
    ' "$CONNECTION_HISTORY_FILE" 2>/dev/null)

    _AVG_CONN_CACHE="${avg:--}"
    _AVG_CONN_CACHE_TIME=$now
    echo "$_AVG_CONN_CACHE"
}

# Get connection snapshot from N hours ago (returns "connected|connecting" or "-|-")
get_connection_snapshot() {
    local hours_ago=$1
    local now=$(date +%s)
    local target=$((now - (hours_ago * 3600)))
    local tolerance=1800

    check_connection_history_reset

    if [ ! -f "$CONNECTION_HISTORY_FILE" ]; then
        echo "-|-"
        return
    fi

    local result=$(awk -F'|' -v target="$target" -v tol="$tolerance" '
        BEGIN { best_diff = tol + 1; best = "-|-" }
        {
            diff = ($1 > target) ? ($1 - target) : (target - $1)
            if (diff < best_diff) {
                best_diff = diff
                best = $2 "|" $3
            }
        }
        END { print best }
    ' "$CONNECTION_HISTORY_FILE" 2>/dev/null)

    echo "${result:--|-}"
}

get_net_speed() {
    # Calculate System Network Speed (Active 0.5s Sample)
    # Returns: "RX_MBPS TX_MBPS"
    local iface=""
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
    else
        iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}')
        [ -z "$iface" ] && iface=$(ip route list default 2>/dev/null | awk '{print $5}')
    fi

    if [ -z "$iface" ]; then
        echo "0.00 0.00"
        return
    fi

    if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v netstat &>/dev/null; then
        local rx1 tx1 rx2 tx2
        rx1=$(netstat -ib -I "$iface" 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++){if($i=="Ibytes")ib=i;if($i=="Obytes")ob=i}} NR>1 {rx+=$ib} END{print rx}')
        tx1=$(netstat -ib -I "$iface" 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++){if($i=="Ibytes")ib=i;if($i=="Obytes")ob=i}} NR>1 {tx+=$ob} END{print tx}')
        sleep 0.5
        rx2=$(netstat -ib -I "$iface" 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++){if($i=="Ibytes")ib=i;if($i=="Obytes")ob=i}} NR>1 {rx+=$ib} END{print rx}')
        tx2=$(netstat -ib -I "$iface" 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++){if($i=="Ibytes")ib=i;if($i=="Obytes")ob=i}} NR>1 {tx+=$ob} END{print tx}')

        if [ -n "$rx1" ] && [ -n "$rx2" ] && [ -n "$tx1" ] && [ -n "$tx2" ]; then
            local rx_delta=$((rx2 - rx1))
            local tx_delta=$((tx2 - tx1))
            local rx_mbps=$(awk -v b="$rx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')
            local tx_mbps=$(awk -v b="$tx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')
            echo "$rx_mbps $tx_mbps"
            return
        fi
    fi

    if [ -n "$iface" ] && [ -f "/sys/class/net/$iface/statistics/rx_bytes" ]; then
        local rx1=$(cat /sys/class/net/$iface/statistics/rx_bytes)
        local tx1=$(cat /sys/class/net/$iface/statistics/tx_bytes)

        sleep 0.5

        local rx2=$(cat /sys/class/net/$iface/statistics/rx_bytes)
        local tx2=$(cat /sys/class/net/$iface/statistics/tx_bytes)

        # Calculate Delta (Bytes)
        local rx_delta=$((rx2 - rx1))
        local tx_delta=$((tx2 - tx1))

        # Convert to Mbps: (bytes * 8 bits) / (0.5 sec * 1,000,000)
        # Formula simplified: bytes * 16 / 1000000
        local rx_mbps=$(awk -v b="$rx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')
        local tx_mbps=$(awk -v b="$tx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')

        echo "$rx_mbps $tx_mbps"
    else
        echo "0.00 0.00"
    fi
}

show_status() {
    sync_settings_from_containers false  # Don't save during live status updates
    local mode="${1:-normal}" # 'live' mode adds line clearing
    local EL=""
    if [ "$mode" == "live" ]; then
        EL="\033[K" # Erase Line escape code
    fi

    echo ""

    local total_containers="$CONTAINER_COUNT"
    local running_containers=0
    local primary_name=""
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local name=$(get_container_name "$i")
        if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            running_containers=$((running_containers + 1))
            [ -z "$primary_name" ] && primary_name="$name"
        fi
    done
    [ -z "$primary_name" ] && primary_name="$(get_container_name 1)"

    if [ "$running_containers" -gt 0 ]; then
        if [ -z "$_PEAK_CONTAINER_START" ]; then
            load_peak_connections
        fi

        # Aggregate stats across containers
        local total_connecting=0
        local total_connected=0
        local total_up_bytes=0
        local total_down_bytes=0
        local uptime=""

        for i in $(seq 1 "$CONTAINER_COUNT"); do
            local cname=$(get_container_name "$i")
            if ! docker ps 2>/dev/null | grep -q "[[:space:]]${cname}$"; then
                continue
            fi
            local logs=$(docker logs --tail 200 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
            if [ -z "$logs" ]; then
                continue
            fi
            local c_connecting c_connected c_up_val c_down_val c_uptime_val
            IFS='|' read -r c_connecting c_connected c_up_val c_down_val c_uptime_val <<< $(echo "$logs" | awk '{
                cing=0; conn=0; up=""; down=""; ut=""
                for(j=1;j<=NF;j++){
                    if($j=="Connecting:") cing=$(j+1)+0
                    else if($j=="Connected:") conn=$(j+1)+0
                    else if($j=="Up:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Down:/)break; up=up (up?" ":"") $k}}
                    else if($j=="Down:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Uptime:/)break; down=down (down?" ":"") $k}}
                    else if($j=="Uptime:"){for(k=j+1;k<=NF;k++){ut=ut (ut?" ":"") $k}}
                }
                printf "%d|%d|%s|%s|%s", cing, conn, up, down, ut
            }')
            total_connecting=$((total_connecting + ${c_connecting:-0}))
            total_connected=$((total_connected + ${c_connected:-0}))
            [ -z "$uptime" ] && uptime="${c_uptime_val}"

            if [ -n "$c_up_val" ]; then
                local up_val=$(echo "$c_up_val" | awk '{print $1}')
                local up_unit=$(echo "$c_up_val" | awk '{print $2}')
                local up_bytes=$(awk -v val="$up_val" -v unit="$up_unit" 'BEGIN{
                    u=toupper(unit); gsub(/I/,"",u);
                    if (u ~ /^KB/) val*=1024;
                    else if (u ~ /^MB/) val*=1048576;
                    else if (u ~ /^GB/) val*=1073741824;
                    else if (u ~ /^TB/) val*=1099511627776;
                    printf "%.0f", val
                }')
                total_up_bytes=$((total_up_bytes + up_bytes))
            fi
            if [ -n "$c_down_val" ]; then
                local down_val=$(echo "$c_down_val" | awk '{print $1}')
                local down_unit=$(echo "$c_down_val" | awk '{print $2}')
                local down_bytes=$(awk -v val="$down_val" -v unit="$down_unit" 'BEGIN{
                    u=toupper(unit); gsub(/I/,"",u);
                    if (u ~ /^KB/) val*=1024;
                    else if (u ~ /^MB/) val*=1048576;
                    else if (u ~ /^GB/) val*=1073741824;
                    else if (u ~ /^TB/) val*=1099511627776;
                    printf "%.0f", val
                }')
                total_down_bytes=$((total_down_bytes + down_bytes))
            fi
        done

        local upload=$(format_bytes "$total_up_bytes")
        local download=$(format_bytes "$total_down_bytes")

        # Get Resource Stats (from primary container)
        local stats=$(get_container_stats "$primary_name")
        local raw_app_cpu=$(echo "$stats" | awk '{print $1}' | tr -d '%')
        local num_cores=$(get_cpu_cores)
        local app_cpu="0%"
        local app_cpu_display=""

        if [[ "$raw_app_cpu" =~ ^[0-9.]+$ ]]; then
            app_cpu=$(awk -v cpu="$raw_app_cpu" -v cores="$num_cores" 'BEGIN {printf "%.2f%%", cpu / cores}')
            if [ "$num_cores" -gt 1 ]; then
                app_cpu_display="${app_cpu} (${raw_app_cpu}% vCPU)"
            else
                app_cpu_display="${app_cpu}"
            fi
        else
            app_cpu="${raw_app_cpu}%"
            app_cpu_display="${app_cpu}"
        fi

        local app_ram=$(echo "$stats" | awk '{print $2, $3, $4}')
        local sys_stats=$(get_system_stats)
        local sys_cpu=$(echo "$sys_stats" | awk '{print $1}')
        local sys_ram_used=$(echo "$sys_stats" | awk '{print $2}')
        local sys_ram_total=$(echo "$sys_stats" | awk '{print $3}')

        local net_speed=$(get_net_speed)
        local rx_mbps=$(echo "$net_speed" | awk '{print $1}')
        local tx_mbps=$(echo "$net_speed" | awk '{print $2}')
        local net_display="↓ ${rx_mbps} Mbps  ↑ ${tx_mbps} Mbps"

        if [ "$total_connected" -gt "$_PEAK_CONNECTIONS" ] 2>/dev/null; then
            _PEAK_CONNECTIONS=$total_connected
            save_peak_connections
        fi
        local avg_conn=$(get_average_connections)

        local status_line="${BOLD}Status:${NC} ${GREEN}Running${NC}"
        [ -n "$uptime" ] && status_line="${status_line} (${uptime})"
        status_line="${status_line}  ${DIM}|${NC}  ${BOLD}Peak:${NC} ${CYAN}${_PEAK_CONNECTIONS}${NC}"
        status_line="${status_line}  ${DIM}|${NC}  ${BOLD}Avg:${NC} ${CYAN}${avg_conn}${NC}"
        echo -e "${status_line}${EL}"
        echo -e "  Containers: ${GREEN}${running_containers}${NC}/${total_containers}    Clients: ${GREEN}${total_connected}${NC} connected, ${YELLOW}${total_connecting}${NC} connecting${EL}"

        echo -e "${EL}"
        echo -e "${CYAN}═══ Traffic (current session) ═══${NC}${EL}"
        record_connection_history "$total_connected" "$total_connecting"
        local snap_6h=$(get_connection_snapshot 6)
        local snap_12h=$(get_connection_snapshot 12)
        local snap_24h=$(get_connection_snapshot 24)
        local conn_6h=$(echo "$snap_6h" | cut -d'|' -f1)
        local conn_12h=$(echo "$snap_12h" | cut -d'|' -f1)
        local conn_24h=$(echo "$snap_24h" | cut -d'|' -f1)
        printf "  Upload:   ${CYAN}%-12s${NC} ${DIM}|${NC} Clients: ${DIM}6h:${NC}${GREEN}%-4s${NC} ${DIM}12h:${NC}${GREEN}%-4s${NC} ${DIM}24h:${NC}${GREEN}%s${NC}${EL}\n" \
            "${upload:-0 B}" "${conn_6h}" "${conn_12h}" "${conn_24h}"
        printf "  Download: ${CYAN}%-12s${NC} ${DIM}|${NC}${EL}\n" "${download:-0 B}"

        echo -e "${EL}"
        echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
        printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "App:" "$app_cpu_display" "$app_ram"
        printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "System:" "$sys_cpu" "$sys_ram_used / $sys_ram_total"
        printf "  %-8s Net: ${YELLOW}%-43s${NC}${EL}\n" "Total:" "$net_display"

    else
        echo -e "${BOLD}Status:${NC} ${RED}Stopped${NC}${EL}"
        echo -e "  Containers: ${YELLOW}${running_containers}${NC}/${total_containers}${EL}"
    fi
    

    
    echo ""
    echo -e "${CYAN}═══ SETTINGS ═══${NC}${EL}"
    echo -e "  Max Clients:  ${MAX_CLIENTS}${EL}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "  Bandwidth:    Unlimited${EL}"
    else
        echo -e "  Bandwidth:    ${BANDWIDTH} Mbps${EL}"
    fi
    echo -e "  Containers:   ${CONTAINER_COUNT}${EL}"
    if [ "$OS_FAMILY" = "macos" ]; then
        local port_end=$((CONTAINER_PORT_BASE + CONTAINER_COUNT - 1))
        echo -e "  Port Base:    ${CONTAINER_PORT_BASE} (${CONTAINER_PORT_BASE}-${port_end})${EL}"
    fi

    
    echo ""
    echo -e "${CYAN}═══ AUTO-START SERVICE ═══${NC}"
    # Check for systemd
    if command -v systemctl &>/dev/null && systemctl is-enabled conduit.service 2>/dev/null | grep -q "enabled"; then
        echo -e "  Auto-start:   ${GREEN}Enabled (systemd)${NC}"
        local svc_status=$(systemctl is-active conduit.service 2>/dev/null)
        echo -e "  Service:      ${svc_status:-unknown}"
        # Check tracker status
        if pgrep -f "conduit-tracker.sh" >/dev/null 2>&1; then
            echo -e "  Tracker:      ${GREEN}Active${NC}"
        else
            echo -e "  Tracker:      ${YELLOW}Inactive${NC}"
        fi
    # Check for OpenRC
    elif command -v rc-status &>/dev/null && rc-status -a 2>/dev/null | grep -q "conduit"; then
        echo -e "  Auto-start:   ${GREEN}Enabled (OpenRC)${NC}"
    # Check for SysVinit
    elif [ -f /etc/init.d/conduit ]; then
        echo -e "  Auto-start:   ${GREEN}Enabled (SysVinit)${NC}"
    else
        echo -e "  Auto-start:   ${YELLOW}Not configured${NC}"
        if [ "$OS_FAMILY" = "macos" ]; then
            echo -e "  Note:         Docker restart policy handles restarts"
        fi
        # Check tracker status for non-systemd systems
        if pgrep -f "conduit-tracker.sh" >/dev/null 2>&1; then
            echo -e "  Tracker:      ${GREEN}Active${NC}"
        else
            echo -e "  Tracker:      ${YELLOW}Inactive${NC}"
        fi
    fi
    
    # Display active clients and top upload stats (if tracker data available)
    local cumulative_file="$PERSIST_DIR/cumulative_data"
    if [ -s "$cumulative_file" ]; then
        echo ""
        
        # Read cumulative traffic data
        declare -A country_up country_down
        while IFS='|' read -r country down up; do
            [ -z "$country" ] && continue
            country_down["$country"]=$down
            country_up["$country"]=$up
        done < "$cumulative_file"
        
        # Get active clients per country
        declare -A country_clients
        local temp_active="/tmp/active_ips_status_$$.tmp"
        > "$temp_active"
        
        for i in $(seq 1 ${CONTAINER_COUNT:-1}); do
            local cname="conduit"
            [ $i -gt 1 ] && cname="conduit-$i"
            
            docker exec "$cname" cat /proc/net/tcp 2>/dev/null | tail -n +2 | while read line; do
                local rem_addr=$(echo "$line" | awk '{print $3}')
                local rem_ip_hex=$(echo "$rem_addr" | cut -d':' -f1)
                [ ${#rem_ip_hex} -ne 8 ] && continue
                
                local ip=$(printf "%d.%d.%d.%d" 0x${rem_ip_hex:6:2} 0x${rem_ip_hex:4:2} 0x${rem_ip_hex:2:2} 0x${rem_ip_hex:0:2})
                echo "$ip" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)' && continue
                echo "$ip"
            done >> "$temp_active"
        done
        
        # Count active clients per country
        if [ -s "$temp_active" ]; then
            sort -u "$temp_active" | while read -r ip; do
                [ -z "$ip" ] && continue
                local country="Unknown"
                
                if command -v mmdblookup >/dev/null 2>&1; then
                    local mmdb_path=""
                    for db in "$INSTALL_DIR/geoip/dbip-country-lite.mmdb" \
                              "$INSTALL_DIR/geoip/GeoLite2-Country.mmdb" \
                              "/usr/local/share/GeoIP/dbip-country-lite.mmdb"; do
                        if [ -f "$db" ]; then
                            mmdb_path="$db"
                            break
                        fi
                    done
                    if [ -n "$mmdb_path" ]; then
                        country=$(mmdblookup --file "$mmdb_path" --ip "$ip" country names en 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | head -1)
                    fi
                fi
                [ -z "$country" ] && country="Unknown"
                echo "$country"
            done | sort | uniq -c | while read count country; do
                echo "${country}|${count}"
            done > "${temp_active}.counts"
            
            while IFS='|' read -r country count; do
                country_clients["$country"]=$count
            done < "${temp_active}.counts"
            rm -f "${temp_active}.counts"
        fi
        rm -f "$temp_active"
        
        # Calculate totals
        local total_active_clients=0
        for country in "${!country_clients[@]}"; do
            total_active_clients=$((total_active_clients + ${country_clients[$country]:-0}))
        done
        
        local total_upload=0
        for country in "${!country_up[@]}"; do
            total_upload=$((total_upload + ${country_up[$country]:-0}))
        done
        
        # Display side-by-side tables
        echo -e "  ${BOLD}ACTIVE CLIENTS${NC}                 ${BOLD}TOP 5 UPLOAD (cumulative)${NC}"
        
        # Get top 5 by active clients
        local active_top5=()
        for country in "${!country_clients[@]}"; do
            local count=${country_clients[$country]:-0}
            local pct=0
            [ $total_active_clients -gt 0 ] && pct=$((count * 100 / total_active_clients))
            echo "${pct}|${count}|${country}"
        done | sort -t'|' -k1 -rn | head -5 | while IFS='|' read -r pct count country; do
            # Truncate country name to 12 chars
            local country_short="${country:0:12}"
            local bar_len=$((pct / 25))
            [ $bar_len -gt 4 ] && bar_len=4
            local bar=$(printf '█%.0s' $(seq 1 $bar_len))
            printf "  %-12s %3s%% %-4s %6s" "$country_short" "$pct" "$bar" "$count"
            echo ""
        done > /tmp/active_$$
        
        # Get top 5 by upload
        for country in "${!country_up[@]}"; do
            local up=${country_up[$country]:-0}
            local pct=0
            [ $total_upload -gt 0 ] && pct=$((up * 100 / total_upload))
            echo "${pct}|${up}|${country}"
        done | sort -t'|' -k1 -rn | head -5 | while IFS='|' read -r pct up country; do
            local country_short="${country:0:12}"
            local bar_len=$((pct / 25))
            [ $bar_len -gt 4 ] && bar_len=4
            local bar=$(printf '█%.0s' $(seq 1 $bar_len))
            local up_fmt=$(format_bytes "$up")
            printf "   %-12s %3s%% %-4s %12s" "$country_short" "$pct" "$bar" "$up_fmt"
            echo ""
        done > /tmp/upload_$$
        
        # Merge and display side by side
        paste /tmp/active_$$ /tmp/upload_$$ | while IFS=$'\t' read -r left right; do
            printf "%s%s\n" "$left" "$right"
        done
        
        rm -f /tmp/active_$$ /tmp/upload_$$
    fi
    
    echo ""
}

start_conduit() {
    echo "Starting Conduit..."
    CONTAINER_COUNT=${CONTAINER_COUNT:-1}

    local started=0
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local name=$(get_container_name "$i")
        local vol=$(get_volume_name "$i")
        if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            echo -e "${GREEN}✓ ${name} is already running${NC}"
            started=$((started + 1))
            continue
        fi
        if docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            echo "Recreating ${name} with stats enabled..."
            docker rm "$name" 2>/dev/null || true
        else
            echo "Creating ${name}..."
        fi
        docker volume create "$vol" 2>/dev/null || true
        fix_volume_permissions "$i"
        run_conduit_container "$i"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ ${name} started${NC}"
            started=$((started + 1))
        else
            echo -e "${RED}✗ Failed to start ${name}${NC}"
        fi
    done

    # Remove extra containers beyond current count
    docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r cname; do
        if [[ "$cname" =~ ^conduit-([0-9]+)$ ]]; then
            local idx="${BASH_REMATCH[1]}"
            if [ "$idx" -gt "$CONTAINER_COUNT" ]; then
                docker rm -f "$cname" 2>/dev/null || true
                echo -e "${YELLOW}✓ ${cname} removed (scaled down)${NC}"
            fi
        fi
    done

    if [ "$started" -gt 0 ]; then
        return 0
    fi
    return 1
}

stop_conduit() {
    echo "Stopping Conduit..."
    CONTAINER_COUNT=${CONTAINER_COUNT:-1}
    local stopped=0
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local name=$(get_container_name "$i")
        if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            docker stop "$name" 2>/dev/null || true
            echo -e "${YELLOW}✓ ${name} stopped${NC}"
            stopped=$((stopped + 1))
        fi
    done
    if [ "$stopped" -eq 0 ]; then
        echo -e "${YELLOW}Conduit is not running${NC}"
    fi
}

restart_conduit() {
    echo "Restarting Conduit..."
    CONTAINER_COUNT=${CONTAINER_COUNT:-1}
    local restarted=0
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local name=$(get_container_name "$i")
        local vol=$(get_volume_name "$i")
        if docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            docker stop "$name" 2>/dev/null || true
            docker rm "$name" 2>/dev/null || true
        fi
        docker volume create "$vol" 2>/dev/null || true
        fix_volume_permissions "$i"
        run_conduit_container "$i"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ ${name} restarted${NC}"
            restarted=$((restarted + 1))
        else
            echo -e "${RED}✗ Failed to restart ${name}${NC}"
        fi
    done

    # Remove extra containers beyond current count
    docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r cname; do
        if [[ "$cname" =~ ^conduit-([0-9]+)$ ]]; then
            local idx="${BASH_REMATCH[1]}"
            if [ "$idx" -gt "$CONTAINER_COUNT" ]; then
                docker rm -f "$cname" 2>/dev/null || true
                echo -e "${YELLOW}✓ ${cname} removed (scaled down)${NC}"
            fi
        fi
    done

    if [ "$restarted" -eq 0 ]; then
        echo -e "${RED}Conduit containers not found. Use 'conduit start' to create them.${NC}"
        return 1
    fi
    return 0
}

change_settings() {
    echo ""
    echo -e "${CYAN}═══ Current Settings ═══${NC}"
    echo ""
    printf "  ${BOLD}%-12s %-12s %-12s${NC}\n" "Container" "Max Clients" "Bandwidth"
    echo -e "  ${CYAN}────────────────────────────────────────${NC}"
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local cname=$(get_container_name "$i")
        local mc=$(get_container_max_clients "$i")
        local bw=$(get_container_bandwidth "$i")
        local bw_display="Unlimited"
        [ "$bw" != "-1" ] && bw_display="${bw} Mbps"
        printf "  %-12s %-12s %-12s\n" "$cname" "$mc" "$bw_display"
    done
    echo ""
    echo -e "  Default: Max Clients=${GREEN}${MAX_CLIENTS}${NC}  Bandwidth=${GREEN}$([ "$BANDWIDTH" = "-1" ] && echo "Unlimited" || echo "${BANDWIDTH} Mbps")${NC}"
    echo -e "  Containers: ${CONTAINER_COUNT}"
    if [ "$OS_FAMILY" = "macos" ]; then
        echo -e "  Port Base:  ${CONTAINER_PORT_BASE} (${CONTAINER_PORT_BASE}-$((CONTAINER_PORT_BASE + CONTAINER_COUNT - 1)))"
    fi
    echo ""

    echo -e "  ${BOLD}Apply settings to:${NC}"
    echo -e "  ${GREEN}a${NC}) All containers (set same values)"
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        echo -e "  ${GREEN}${i}${NC}) $(get_container_name "$i")"
    done
    echo ""
    read -p "  Select (a/1-${CONTAINER_COUNT}): " target < /dev/tty || true

    local targets=()
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        for i in $(seq 1 "$CONTAINER_COUNT"); do targets+=($i); done
    elif [[ "$target" =~ ^[0-9]+$ ]] && [ "$target" -ge 1 ] && [ "$target" -le "$CONTAINER_COUNT" ]; then
        targets+=($target)
    else
        echo -e "  ${RED}Invalid selection.${NC}"
        return
    fi

    local cur_mc=$(get_container_max_clients "${targets[0]}")
    local cur_bw=$(get_container_bandwidth "${targets[0]}")
    echo ""
    read -p "  New max-clients (1-1000) [${cur_mc}]: " new_clients < /dev/tty || true

    echo ""
    local cur_bw_display="Unlimited"
    [ "$cur_bw" != "-1" ] && cur_bw_display="${cur_bw} Mbps"
    echo "  Current bandwidth: ${cur_bw_display}"
    read -p "  Set unlimited bandwidth? [y/N]: " set_unlimited < /dev/tty || true

    local new_bandwidth=""
    if [[ "$set_unlimited" =~ ^[Yy]$ ]]; then
        new_bandwidth="-1"
    else
        read -p "  New bandwidth in Mbps (1-40) [${cur_bw}]: " input_bw < /dev/tty || true
        [ -n "$input_bw" ] && new_bandwidth="$input_bw"
    fi

    # Validate max-clients
    local valid_mc=""
    if [ -n "$new_clients" ]; then
        if [[ "$new_clients" =~ ^[0-9]+$ ]] && [ "$new_clients" -ge 1 ] && [ "$new_clients" -le 1000 ]; then
            valid_mc="$new_clients"
        else
            echo -e "  ${YELLOW}Invalid max-clients. Keeping current.${NC}"
        fi
    fi

    # Validate bandwidth
    local valid_bw=""
    if [ -n "$new_bandwidth" ]; then
        if [ "$new_bandwidth" = "-1" ]; then
            valid_bw="-1"
        elif [[ "$new_bandwidth" =~ ^[0-9]+$ ]] && [ "$new_bandwidth" -ge 1 ] && [ "$new_bandwidth" -le 40 ]; then
            valid_bw="$new_bandwidth"
        elif [[ "$new_bandwidth" =~ ^[0-9]*\.[0-9]+$ ]]; then
            local float_ok=$(awk -v val="$new_bandwidth" 'BEGIN { print (val >= 1 && val <= 40) ? "yes" : "no" }')
            [ "$float_ok" = "yes" ] && valid_bw="$new_bandwidth" || echo -e "  ${YELLOW}Invalid bandwidth. Keeping current.${NC}"
        else
            echo -e "  ${YELLOW}Invalid bandwidth. Keeping current.${NC}"
        fi
    fi

    local new_container_count="$CONTAINER_COUNT"
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        echo ""
        if [ "$OS_FAMILY" = "macos" ]; then
            echo "Note: macOS uses per-container ports (443, 444, 445...)"
        fi
        read -p "  New container count (1-32) [${CONTAINER_COUNT}]: " input_containers < /dev/tty || true
        if [ -n "$input_containers" ]; then
            if [[ "$input_containers" =~ ^[1-9][0-9]*$ ]]; then
                new_container_count=$input_containers
                if [ "$new_container_count" -gt 32 ]; then
                    echo -e "${YELLOW}Maximum is 32 containers. Setting to 32.${NC}"
                    new_container_count=32
                fi
            else
                echo -e "${YELLOW}Invalid container count. Keeping current: ${CONTAINER_COUNT}${NC}"
            fi
        fi
    fi

    # Apply to targets
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        [ -n "$valid_mc" ] && MAX_CLIENTS="$valid_mc"
        [ -n "$valid_bw" ] && BANDWIDTH="$valid_bw"
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            unset "MAX_CLIENTS_${i}" 2>/dev/null || true
            unset "BANDWIDTH_${i}" 2>/dev/null || true
        done
    else
        local idx=${targets[0]}
        if [ -n "$valid_mc" ]; then
            eval "MAX_CLIENTS_${idx}=${valid_mc}"
        fi
        if [ -n "$valid_bw" ]; then
            eval "BANDWIDTH_${idx}=${valid_bw}"
        fi
    fi

    local recreate_all=false
    if [ "$new_container_count" -ne "$CONTAINER_COUNT" ]; then
        CONTAINER_COUNT="$new_container_count"
        recreate_all=true
    fi

    save_settings

    echo ""
    echo "  Recreating container(s) with new settings..."
    local target_list=()
    if [ "$recreate_all" = true ] || [ "$target" = "a" ] || [ "$target" = "A" ]; then
        for i in $(seq 1 "$CONTAINER_COUNT"); do target_list+=($i); done
    else
        target_list=("${targets[@]}")
    fi
    for i in "${target_list[@]}"; do
        local name=$(get_container_name "$i")
        docker rm -f "$name" 2>/dev/null || true
    done
    sleep 1
    for i in "${target_list[@]}"; do
        local name=$(get_container_name "$i")
        local vol=$(get_volume_name "$i")
        docker volume create "$vol" 2>/dev/null || true
        fix_volume_permissions "$i"
        run_conduit_container "$i"
        if [ $? -eq 0 ]; then
            local mc=$(get_container_max_clients "$i")
            local bw=$(get_container_bandwidth "$i")
            local bw_d="Unlimited"
            [ "$bw" != "-1" ] && bw_d="${bw} Mbps"
            echo -e "  ${GREEN}✓ ${name}${NC} — clients: ${mc}, bandwidth: ${bw_d}"
        else
            echo -e "  ${RED}✗ Failed to restart ${name}${NC}"
        fi
    done

    # Remove extra containers beyond current count
    docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r cname; do
        if [[ "$cname" =~ ^conduit-([0-9]+)$ ]]; then
            local idx="${BASH_REMATCH[1]}"
            if [ "$idx" -gt "$CONTAINER_COUNT" ]; then
                docker rm -f "$cname" 2>/dev/null || true
                echo -e "  ${YELLOW}✓ ${cname} removed (scaled down)${NC}"
            fi
        fi
    done
    setup_tracker_service
}

change_resource_limits() {
    local cpu_cores=$(get_cpu_cores)
    local ram_mb=$(get_ram_mb)
    echo ""
    echo -e "${CYAN}═══ RESOURCE LIMITS ═══${NC}"
    echo ""
    echo -e "  Set CPU and memory limits per container."
    echo -e "  ${DIM}System: ${cpu_cores} CPU core(s), ${ram_mb} MB RAM${NC}"
    echo ""

    printf "  ${BOLD}%-12s %-12s %-12s${NC}\n" "Container" "CPU Limit" "Memory Limit"
    echo -e "  ${CYAN}────────────────────────────────────────${NC}"
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local cname=$(get_container_name "$i")
        local cpus=$(get_container_cpus "$i")
        local mem=$(get_container_memory "$i")
        local cpu_d="${cpus:-No limit}"
        local mem_d="${mem:-No limit}"
        [ -n "$cpus" ] && cpu_d="${cpus} cores"
        printf "  %-12s %-12s %-12s\n" "$cname" "$cpu_d" "$mem_d"
    done
    echo ""

    echo -e "  ${BOLD}Apply limits to:${NC}"
    echo -e "  ${GREEN}a${NC}) All containers"
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        echo -e "  ${GREEN}${i}${NC}) $(get_container_name "$i")"
    done
    echo -e "  ${GREEN}c${NC}) Clear all limits (remove restrictions)"
    echo ""
    read -p "  Select (a/1-${CONTAINER_COUNT}/c): " target < /dev/tty || true

    if [ "$target" = "c" ] || [ "$target" = "C" ]; then
        DOCKER_CPUS=""
        DOCKER_MEMORY=""
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            unset "CPUS_${i}" 2>/dev/null || true
            unset "MEMORY_${i}" 2>/dev/null || true
        done
        save_settings
        echo ""
        echo "  Recreating containers without limits..."
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            local name=$(get_container_name "$i")
            docker rm -f "$name" 2>/dev/null || true
        done
        sleep 1
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            fix_volume_permissions "$i"
            run_conduit_container "$i"
        done
        echo -e "  ${GREEN}✓ Resource limits cleared${NC}"
        setup_tracker_service
        return
    fi

    local targets=()
    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        for i in $(seq 1 "$CONTAINER_COUNT"); do targets+=($i); done
    elif [[ "$target" =~ ^[0-9]+$ ]] && [ "$target" -ge 1 ] && [ "$target" -le "$CONTAINER_COUNT" ]; then
        targets+=($target)
    else
        echo -e "  ${RED}Invalid selection.${NC}"
        return
    fi

    echo ""
    read -p "  CPU limit (cores, e.g. 1.5) [keep current]: " input_cpus < /dev/tty || true
    read -p "  Memory limit (e.g. 512m or 2g) [keep current]: " input_mem < /dev/tty || true

    local valid_cpus=""
    local valid_mem=""
    if [ -n "$input_cpus" ]; then
        if [[ "$input_cpus" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            valid_cpus="$input_cpus"
        else
            echo -e "  ${YELLOW}Invalid CPU value. Keeping current.${NC}"
        fi
    fi
    if [ -n "$input_mem" ]; then
        if [[ "$input_mem" =~ ^[0-9]+[mMgG]$ ]]; then
            valid_mem="$input_mem"
        else
            echo -e "  ${YELLOW}Invalid memory value. Use e.g. 512m or 2g.${NC}"
        fi
    fi

    if [ "$target" = "a" ] || [ "$target" = "A" ]; then
        [ -n "$valid_cpus" ] && DOCKER_CPUS="$valid_cpus"
        [ -n "$valid_mem" ] && DOCKER_MEMORY="$valid_mem"
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            unset "CPUS_${i}" 2>/dev/null || true
            unset "MEMORY_${i}" 2>/dev/null || true
        done
    else
        local idx=${targets[0]}
        [ -n "$valid_cpus" ] && eval "CPUS_${idx}=${valid_cpus}"
        [ -n "$valid_mem" ] && eval "MEMORY_${idx}=${valid_mem}"
    fi

    save_settings

    echo ""
    echo "  Recreating container(s) with new limits..."
    for i in "${targets[@]}"; do
        local name=$(get_container_name "$i")
        docker rm -f "$name" 2>/dev/null || true
    done
    sleep 1
    for i in "${targets[@]}"; do
        fix_volume_permissions "$i"
        run_conduit_container "$i"
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}✓ $(get_container_name "$i") updated${NC}"
        else
            echo -e "  ${RED}✗ Failed to update $(get_container_name "$i")${NC}"
        fi
    done
    setup_tracker_service
}

#═══════════════════════════════════════════════════════════════════════
# show_logs() - Display color-coded Docker logs
#═══════════════════════════════════════════════════════════════════════
# Colors log entries based on their type:
#   [OK]     - Green   (successful operations)
#   [INFO]   - Cyan    (informational messages)
#   [STATS]  - Blue    (statistics)
#   [WARN]   - Yellow  (warnings)
#   [ERROR]  - Red     (errors)
#   [DEBUG]  - Gray    (debug messages)
#═══════════════════════════════════════════════════════════════════════
show_logs() {
    if ! docker ps -a 2>/dev/null | grep -q conduit; then
        echo -e "${RED}Conduit container not found.${NC}"
        return 1
    fi
    
    local target_name="conduit"
    if [ "$CONTAINER_COUNT" -gt 1 ]; then
        echo ""
        echo -e "${CYAN}Select container logs to view:${NC}"
        for i in $(seq 1 "$CONTAINER_COUNT"); do
            echo -e "  ${GREEN}${i}${NC}) $(get_container_name "$i")"
        done
        echo ""
        read -p "  Choose [1-${CONTAINER_COUNT}] (default 1): " log_choice < /dev/tty || true
        if [[ "$log_choice" =~ ^[0-9]+$ ]] && [ "$log_choice" -ge 1 ] && [ "$log_choice" -le "$CONTAINER_COUNT" ]; then
            target_name=$(get_container_name "$log_choice")
        fi
    fi

    echo -e "${CYAN}Streaming logs for ${target_name} (filtered, no [STATS])... Press Ctrl+C to stop${NC}"
    echo ""

    # Stream ALL docker logs, filtering out [STATS] lines for cleaner output
    docker logs -f "$target_name" 2>&1 | grep -v "\[STATS\]"
}

uninstall_all() {
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  UNINSTALL CONDUIT                          ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "This will completely remove:"
    echo "  • Conduit Docker containers"
    echo "  • Conduit Docker image"
    echo "  • Conduit data volumes (all stored data)"
    echo "  • Auto-start service (systemd/OpenRC/SysVinit)"
    echo "  • Configuration files"
    echo "  • Management CLI"
    echo ""
    echo -e "${RED}WARNING: This action cannot be undone!${NC}"
    echo ""
    read -p "Are you sure you want to uninstall? (type 'yes' to confirm): " confirm < /dev/tty || true

    if [ "$confirm" != "yes" ]; then
        echo "Uninstall cancelled."
        return 0
    fi

    # Check for backup keys
    local keep_backups=false
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
        echo ""
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  📁 Backup keys found in: ${BACKUP_DIR}${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "You have backed up node identity keys. These allow you to restore"
        echo "your node identity if you reinstall Conduit later."
        echo ""
        read -p "Do you want to KEEP your backup keys? (y/n): " keep_confirm < /dev/tty || true

        if [ "$keep_confirm" = "y" ] || [ "$keep_confirm" = "Y" ]; then
            keep_backups=true
            echo -e "${GREEN}✓ Backup keys will be preserved.${NC}"
        else
            echo -e "${YELLOW}⚠ Backup keys will be deleted.${NC}"
        fi
        echo ""
    fi

    echo ""
    echo -e "${BLUE}[INFO]${NC} Stopping Conduit containers..."
    docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r cname; do
        if [[ "$cname" =~ ^conduit(-([0-9]+))?$ ]]; then
            docker stop "$cname" 2>/dev/null || true
            docker rm -f "$cname" 2>/dev/null || true
        fi
    done

    echo -e "${BLUE}[INFO]${NC} Removing Conduit Docker image..."
    docker rmi "$CONDUIT_IMAGE" 2>/dev/null || true

    echo -e "${BLUE}[INFO]${NC} Removing Conduit data volumes..."
    docker volume ls --format '{{.Name}}' 2>/dev/null | while read -r vname; do
        if [[ "$vname" =~ ^conduit-data(-([0-9]+))?$ ]]; then
            docker volume rm "$vname" 2>/dev/null || true
        fi
    done

    echo -e "${BLUE}[INFO]${NC} Removing auto-start service..."
    # Systemd
    systemctl stop conduit.service 2>/dev/null || true
    systemctl disable conduit.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service
    systemctl daemon-reload 2>/dev/null || true
    # OpenRC / SysVinit
    rc-service conduit stop 2>/dev/null || true
    rc-update del conduit 2>/dev/null || true
    service conduit stop 2>/dev/null || true
    update-rc.d conduit remove 2>/dev/null || true
    chkconfig conduit off 2>/dev/null || true
    rm -f /etc/init.d/conduit

    echo -e "${BLUE}[INFO]${NC} Removing configuration files..."
    if [ "$keep_backups" = true ]; then
        # Keep backup directory, remove everything else in /opt/conduit
        echo -e "${BLUE}[INFO]${NC} Preserving backup keys in ${BACKUP_DIR}..."
        # Remove files in /opt/conduit but keep backups subdirectory
        rm -f /opt/conduit/config.env 2>/dev/null || true
        rm -f /opt/conduit/conduit 2>/dev/null || true
        find /opt/conduit -maxdepth 1 -type f -delete 2>/dev/null || true
    else
        # Remove everything including backups
        rm -rf /opt/conduit
    fi
    rm -f /usr/local/bin/conduit

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ UNINSTALL COMPLETE!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Conduit and all related components have been removed."
    if [ "$keep_backups" = true ]; then
        echo ""
        echo -e "${CYAN}📁 Your backup keys are preserved in: ${BACKUP_DIR}${NC}"
        echo "   You can use these to restore your node identity after reinstalling."
    fi
    echo ""
    echo "Note: Docker itself was NOT removed."
    echo ""
}

show_menu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            print_header

            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  MANAGEMENT OPTIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "  1. 📈 View status dashboard"
            echo -e "  2. 📦 View status dashboard (per-container)"
            echo -e "  3. 📊 Live connection stats"
            echo -e "  4. 📋 View logs"
            echo -e "  5. ⚙️  Change settings (per-container)"
            echo -e "  6. 🧮 Resource limits (CPU/Memory)"
            echo ""
            echo -e "  7. 🔄 Update Conduit"
            echo -e "  8. ▶️  Start Conduit"
            echo -e "  9. ⏹️  Stop Conduit"
            echo -e "  10. 🔁 Restart Conduit"
            echo ""
            echo -e "  11. 🌍 View live peers by country (Live Map)"
            echo -e "  g. 🌐 Update GeoIP database (DB-IP Lite)"
            echo ""
            echo -e "  h. 🩺 Health check"
            local tracker_enabled_status
            if [ "${TRACKER_ENABLED:-true}" = "true" ]; then
                tracker_enabled_status="${GREEN}Enabled${NC}"
            else
                tracker_enabled_status="${RED}Disabled${NC}"
            fi
            echo -e "  d. 📡 Toggle tracker (${tracker_enabled_status}) — saves CPU when off"
            echo -e "  t. 📲 Telegram Notifications"
            echo -e "  b. 💾 Backup node key"
            echo -e "  r. 📥 Restore node key"
            echo ""
            echo -e "  u. 🗑️  Uninstall (remove everything)"
            echo -e "  v. ℹ️  Version info"
            echo -e "  0. 🚪 Exit"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            redraw=false
        fi
        
        read -p "  Enter choice: " choice < /dev/tty || { echo "Input error. Exiting."; exit 1; }
            
        case $choice in
            1)
                show_dashboard
                redraw=true
                ;;
            2)
                show_container_dashboard
                redraw=true
                ;;
            3)
                show_live_stats
                redraw=true
                ;;
            4)
                show_logs
                redraw=true
                ;;
            5)
                change_settings
                redraw=true
                ;;
            6)
                change_resource_limits
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            7)
                update_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            8)
                start_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            9)
                stop_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            10)
                restart_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            11)
                show_peers
                redraw=true
                ;;
            d|D)
                toggle_tracker
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            t|T)
                show_telegram_menu
                redraw=true
                ;;
            g|G)
                update_geoip_db
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            h|H)
                health_check
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            b|B)
                backup_key
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            r|R)
                restore_key
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            u)
                uninstall_all
                exit 0
                ;;
            v|V)
                show_version
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            0)
                echo "Exiting."
                exit 0
                ;;
            "")
                # Ignore empty Enter key
                ;;
            *)
                echo -e "${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}"
                echo -e "${CYAN}Choose an option from 0-11, h, b, r, u, or v.${NC}"
                ;;
        esac
    done
}

# Command line interface
show_help() {
    echo "Usage: conduit [command]"
    echo ""
    echo "Commands:"
    echo "  status    Show current status with resource usage"
    echo "  stats     View live statistics"
    echo "  logs      View raw Docker logs"
    echo "  containers  Per-container dashboard"
    echo "  tracker   Toggle tracker"
    echo "  telegram  Telegram Notifications menu"
    echo "  health    Run health check on Conduit container"
    echo "  start     Start Conduit container"
    echo "  stop      Stop Conduit container"
    echo "  restart   Restart Conduit container"
    echo "  update    Update to latest Conduit image"
    echo "  geoip-update  Update DB-IP Lite GeoIP database (macOS)"
    echo "  settings  Change per-container max-clients/bandwidth"
    echo "  limits    Change per-container CPU/memory limits"
    echo "  backup    Backup Conduit node identity key"
    echo "  restore   Restore Conduit node identity from backup"
    echo "  uninstall Remove everything (container, data, service)"
    echo "  menu      Open interactive menu (default)"
    echo "  version   Show version information"
    echo "  help      Show this help"
}

show_version() {
    echo "Conduit Manager v${VERSION}"
    echo "Image: ${CONDUIT_IMAGE}"

    # Show actual running image digest if available
    if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        local actual=$(docker inspect --format='{{index .RepoDigests 0}}' "$CONDUIT_IMAGE" 2>/dev/null | grep -o 'sha256:[a-f0-9]*')
        if [ -n "$actual" ]; then
            echo "Running Digest:  ${actual}"
        fi
    fi
}

health_check() {
    echo -e "${CYAN}═══ CONDUIT HEALTH CHECK ═══${NC}"
    echo ""

    local all_ok=true

    # 1. Check if Docker is running
    echo -n "Docker daemon:        "
    if docker info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Docker is not running"
        all_ok=false
    fi

    # 2. Check if container exists
    echo -n "Container exists:     "
    if docker ps -a 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Container not found"
        all_ok=false
    fi

    # 3. Check if container is running
    echo -n "Container running:    "
    if docker ps 2>/dev/null | grep -q "[[:space:]]conduit$"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Container is stopped"
        all_ok=false
    fi

    # 4. Check container health/restart count
    echo -n "Restart count:        "
    local restarts=$(docker inspect --format='{{.RestartCount}}' conduit 2>/dev/null)
    if [ -n "$restarts" ]; then
        if [ "$restarts" -eq 0 ]; then
            echo -e "${GREEN}${restarts}${NC} (healthy)"
        elif [ "$restarts" -lt 5 ]; then
            echo -e "${YELLOW}${restarts}${NC} (some restarts)"
        else
            echo -e "${RED}${restarts}${NC} (excessive restarts)"
            all_ok=false
        fi
    else
        echo -e "${YELLOW}N/A${NC}"
    fi

    # 5. Check if Conduit has connected to network
    echo -n "Network connection:   "
    local connected=$(docker logs --tail 100 conduit 2>&1 | grep -c "Connected to Psiphon" || true)
    if [ "$connected" -gt 0 ]; then
        echo -e "${GREEN}OK${NC} (Connected to Psiphon network)"
    else
        local info_lines=$(docker logs --tail 100 conduit 2>&1 | grep -c "\[INFO\]" || true)
        if [ "$info_lines" -gt 0 ]; then
            echo -e "${YELLOW}CONNECTING${NC} - Establishing connection..."
        else
            echo -e "${YELLOW}WAITING${NC} - Starting up..."
        fi
    fi

    # 5b. Check if stats output is enabled (stats file or log output)
    echo -n "Stats output:         "
    local stats_ok=false
    local stats_path=""
    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)
    if [ -n "$mountpoint" ]; then
        stats_path="$mountpoint/conduit_stats.json"
        if [ -s "$stats_path" ]; then
            stats_ok=true
        fi
    fi
    if [ "$stats_ok" = false ]; then
        local stats_count=$(docker logs --tail 200 conduit 2>&1 | grep -c "\[STATS\]" || true)
        if [ "$stats_count" -gt 0 ]; then
            stats_ok=true
        fi
    fi
    if [ "$stats_ok" = true ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}NONE${NC} - Run 'conduit restart' and wait 30-60s"
    fi

    # 6. Check data volume
    echo -n "Data volume:          "
    if docker volume inspect conduit-data &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC} - Volume not found"
        all_ok=false
    fi

    # 7. Check node key exists
    echo -n "Node identity key:    "
    if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}PENDING${NC} - Will be created on first run"
    fi

    # 8. Check network connectivity (port binding)
    echo -n "Network (host mode):  "
    local network_mode=$(docker inspect --format='{{.HostConfig.NetworkMode}}' conduit 2>/dev/null)
    if [ "$network_mode" = "host" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}WARN${NC} - Not using host network mode"
    fi

    echo ""
    if [ "$all_ok" = true ]; then
        echo -e "${GREEN}✓ All health checks passed${NC}"
        return 0
    else
        echo -e "${RED}✗ Some health checks failed${NC}"
        return 1
    fi
}

backup_key() {
    echo -e "${CYAN}═══ BACKUP CONDUIT NODE KEY ═══${NC}"
    echo ""

    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)

    if [ -z "$mountpoint" ]; then
        echo -e "${RED}Error: Could not find conduit-data volume${NC}"
        return 1
    fi

    if [ ! -f "$mountpoint/conduit_key.json" ]; then
        echo -e "${RED}Error: No node key found. Has Conduit been started at least once?${NC}"
        return 1
    fi

    # Create backup directory
    mkdir -p "$INSTALL_DIR/backups"

    # Create timestamped backup
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="$INSTALL_DIR/backups/conduit_key_${timestamp}.json"

    cp "$mountpoint/conduit_key.json" "$backup_file"
    chmod 600 "$backup_file"

    # Get node ID for display
    local node_id=$(cat "$mountpoint/conduit_key.json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n')

    echo -e "${GREEN}✓ Backup created successfully${NC}"
    echo ""
    echo "  Backup file: ${CYAN}${backup_file}${NC}"
    echo "  Node ID:     ${CYAN}${node_id}${NC}"
    echo ""
    echo -e "${YELLOW}Important:${NC} Store this backup securely. It contains your node's"
    echo "private key which identifies your node on the Psiphon network."
    echo ""

    # List all backups
    echo "All backups:"
    ls -la "$INSTALL_DIR/backups/"*.json 2>/dev/null | awk '{print "  " $9 " (" $5 " bytes)"}'
}

restore_key() {
    echo -e "${CYAN}═══ RESTORE CONDUIT NODE KEY ═══${NC}"
    echo ""

    local backup_dir="$INSTALL_DIR/backups"

    # Check if backup directory exists and has files
    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A $backup_dir/*.json 2>/dev/null)" ]; then
        echo -e "${YELLOW}No backups found in ${backup_dir}${NC}"
        echo ""
        echo "To restore from a custom path, provide the file path:"
        read -p "  Backup file path (or press Enter to cancel): " custom_path < /dev/tty || true

        if [ -z "$custom_path" ]; then
            echo "Restore cancelled."
            return 0
        fi

        if [ ! -f "$custom_path" ]; then
            echo -e "${RED}Error: File not found: ${custom_path}${NC}"
            return 1
        fi

        backup_file="$custom_path"
    else
        # List available backups
        echo "Available backups:"
        local i=1
        local backups=()
        for f in "$backup_dir"/*.json; do
            backups+=("$f")
            local node_id=$(cat "$f" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null)
            echo "  ${i}. $(basename "$f") - Node: ${node_id:-unknown}"
            i=$((i + 1))
        done
        echo ""

        read -p "  Select backup number (or 0 to cancel): " selection < /dev/tty || true

        if [ "$selection" = "0" ] || [ -z "$selection" ]; then
            echo "Restore cancelled."
            return 0
        fi

        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then
            echo -e "${RED}Invalid selection${NC}"
            return 1
        fi

        backup_file="${backups[$((selection - 1))]}"
    fi

    echo ""
    echo -e "${YELLOW}Warning:${NC} This will replace the current node key."
    echo "The container will be stopped and restarted."
    echo ""
    read -p "Proceed with restore? [y/N] " confirm < /dev/tty || true

    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo "Restore cancelled."
        return 0
    fi

    # Stop container
    echo ""
    echo "Stopping Conduit..."
    docker stop conduit 2>/dev/null || true

    # Get volume mountpoint
    local mountpoint=$(docker volume inspect conduit-data --format '{{ .Mountpoint }}' 2>/dev/null)

    if [ -z "$mountpoint" ]; then
        echo -e "${RED}Error: Could not find conduit-data volume${NC}"
        return 1
    fi

    # Backup current key if exists
    if [ -f "$mountpoint/conduit_key.json" ]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        mkdir -p "$backup_dir"
        cp "$mountpoint/conduit_key.json" "$backup_dir/conduit_key_pre_restore_${timestamp}.json"
        echo "  Current key backed up to: conduit_key_pre_restore_${timestamp}.json"
    fi

    # Restore the key
    cp "$backup_file" "$mountpoint/conduit_key.json"
    chmod 600 "$mountpoint/conduit_key.json"

    # Restart container
    echo "Starting Conduit..."
    docker start conduit 2>/dev/null

    local node_id=$(cat "$mountpoint/conduit_key.json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n')

    echo ""
    echo -e "${GREEN}✓ Node key restored successfully${NC}"
    echo "  Node ID: ${CYAN}${node_id}${NC}"
}

update_conduit() {
    echo -e "${CYAN}═══ UPDATE CONDUIT ═══${NC}"
    echo ""

    echo "Current image: ${CONDUIT_IMAGE}"
    echo ""

    # Check for updates by pulling
    echo "Checking for updates..."
    if ! docker pull $CONDUIT_IMAGE 2>/dev/null; then
        echo -e "${RED}Failed to check for updates. Check your internet connection.${NC}"
        return 1
    fi


    echo ""
    echo "Recreating containers with updated image..."

    local updated=0
    for i in $(seq 1 "$CONTAINER_COUNT"); do
        local name=$(get_container_name "$i")
        docker rm -f "$name" 2>/dev/null || true
        fix_volume_permissions "$i"
        run_conduit_container "$i"
        if [ $? -eq 0 ]; then
            updated=$((updated + 1))
        fi
    done

    if [ "$updated" -eq "$CONTAINER_COUNT" ]; then
        echo -e "${GREEN}✓ Conduit updated and restarted (${updated}/${CONTAINER_COUNT})${NC}"
    else
        echo -e "${RED}✗ Failed to start updated containers (${updated}/${CONTAINER_COUNT})${NC}"
        return 1
    fi
}

load_settings

case "${1:-menu}" in
    status)   show_status ;;
    containers) show_container_dashboard ;;
    stats)    show_live_stats ;;
    logs)     show_logs ;;
    health)   health_check ;;
    start)    start_conduit ;;
    stop)     stop_conduit ;;
    restart)  restart_conduit ;;
    update)   update_conduit ;;
    geoip-update|geoip) update_geoip_db ;;
    peers)    show_peers ;;
    settings) change_settings ;;
    limits|resources) change_resource_limits ;;
    tracker)  toggle_tracker ;;
    telegram) show_telegram_menu ;;
    backup)   backup_key ;;
    restore)  restore_key ;;
    uninstall) uninstall_all ;;
    version|-v|--version) show_version ;;
    help|-h|--help) show_help ;;
    menu|*)   show_menu ;;
esac
MANAGEMENT

    # Patch the INSTALL_DIR in the generated script
    # Use portable in-place sed (GNU sed vs BSD/macOS sed)
    if sed --version >/dev/null 2>&1; then
        # GNU sed (Linux)
        sed -i "s#REPLACE_ME_INSTALL_DIR#$INSTALL_DIR#g" "$INSTALL_DIR/conduit"
    else
        # BSD sed (macOS)
        sed -i '' "s#REPLACE_ME_INSTALL_DIR#$INSTALL_DIR#g" "$INSTALL_DIR/conduit"
    fi
    
    chmod +x "$INSTALL_DIR/conduit"
    # Force create symlink
    if [ "$OS_FAMILY" = "macos" ]; then
        # Prefer Homebrew prefix on Apple Silicon; fall back to /usr/local for Intel/brew variants.
        local brew_prefix=""
        command -v brew &>/dev/null && brew_prefix="$(brew --prefix 2>/dev/null || true)"
        local link_dir="${brew_prefix:-/usr/local}/bin"
        local link_path="$link_dir/conduit"

        if [ -n "$link_dir" ] && [ -d "$link_dir" ] && [ -w "$link_dir" ]; then
            rm -f "$link_path" 2>/dev/null || true
            ln -s "$INSTALL_DIR/conduit" "$link_path"
            log_success "Management script installed: conduit"
            log_info "Run it with: conduit"
        else
            log_warn "Could not install a global 'conduit' command (no write access to ${link_dir})."
            log_info "You can run it directly:"
            log_info "  $INSTALL_DIR/conduit"
            log_info "Or install the symlink yourself:"
            log_info "  sudo ln -sf \"$INSTALL_DIR/conduit\" \"${link_path}\""
        fi
    else
        rm -f /usr/local/bin/conduit 2>/dev/null || true
        ln -s "$INSTALL_DIR/conduit" /usr/local/bin/conduit
        log_success "Management script installed: conduit"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Summary
#═══════════════════════════════════════════════════════════════════════

print_summary() {
    local init_type="Enabled"
    if [ "$HAS_SYSTEMD" = "true" ]; then
        init_type="Enabled (systemd)"
    elif command -v rc-update &>/dev/null; then
        init_type="Enabled (OpenRC)"
    elif [ -d /etc/init.d ]; then
        init_type="Enabled (SysVinit)"
    fi
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ INSTALLATION COMPLETE!                      ║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Conduit is running and ready to help users!                      ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  📊 Settings:                                                     ${GREEN}║${NC}"
    printf "${GREEN}║${NC}     Max Clients: ${CYAN}%-4s${NC}                                             ${GREEN}║${NC}\n" "${MAX_CLIENTS}"
    if [ "$BANDWIDTH" == "-1" ]; then
        echo -e "${GREEN}║${NC}     Bandwidth:   ${CYAN}Unlimited${NC}                                        ${GREEN}║${NC}"
    else
        printf "${GREEN}║${NC}     Bandwidth:   ${CYAN}%-4s${NC} Mbps                                        ${GREEN}║${NC}\n" "${BANDWIDTH}"
    fi
    printf "${GREEN}║${NC}     Containers:  ${CYAN}%-4s${NC}                                             ${GREEN}║${NC}\n" "${CONTAINER_COUNT}"
    printf "${GREEN}║${NC}     Auto-start:  ${CYAN}%-20s${NC}                             ${GREEN}║${NC}\n" "${init_type}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  COMMANDS:                                                        ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit${NC}               # Open management menu                     ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit stats${NC}         # View live statistics + CPU/RAM           ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit status${NC}        # Quick status with resource usage         ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit logs${NC}          # View raw logs                            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit settings${NC}      # Change max-clients/bandwidth/containers ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}conduit uninstall${NC}     # Remove everything                        ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                   ${GREEN}║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}View live stats now:${NC} conduit stats"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Uninstall Function
#═══════════════════════════════════════════════════════════════════════

uninstall() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo "║                    ⚠️  UNINSTALL CONDUIT                          ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "This will completely remove:"
    echo "  • Conduit Docker containers"
    echo "  • Conduit Docker image"
    echo "  • Conduit data volumes (all stored data)"
    echo "  • Auto-start service (systemd/OpenRC/SysVinit)"
    echo "  • Configuration files"
    echo "  • Management CLI"
    echo ""
    echo -e "${RED}WARNING: This action cannot be undone!${NC}"
    echo ""
    read -p "Are you sure you want to uninstall? (type 'yes' to confirm): " confirm < /dev/tty || true
    
    if [ "$confirm" != "yes" ]; then
        echo "Uninstall cancelled."
        exit 0
    fi
    
    echo ""
    log_info "Stopping Conduit containers..."
    docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r cname; do
        if [[ "$cname" =~ ^conduit(-([0-9]+))?$ ]]; then
            docker stop "$cname" 2>/dev/null || true
            docker rm -f "$cname" 2>/dev/null || true
        fi
    done
    
    log_info "Removing Conduit Docker image..."
    docker rmi "$CONDUIT_IMAGE" 2>/dev/null || true
    
    log_info "Removing Conduit data volume..."
    docker volume ls --format '{{.Name}}' 2>/dev/null | while read -r vname; do
        if [[ "$vname" =~ ^conduit-data(-([0-9]+))?$ ]]; then
            docker volume rm "$vname" 2>/dev/null || true
        fi
    done
    
    log_info "Removing auto-start service..."
    # Systemd
    systemctl stop conduit.service 2>/dev/null || true
    systemctl disable conduit.service 2>/dev/null || true
    rm -f /etc/systemd/system/conduit.service
    systemctl daemon-reload 2>/dev/null || true
    # OpenRC / SysVinit
    rc-service conduit stop 2>/dev/null || true
    rc-update del conduit 2>/dev/null || true
    service conduit stop 2>/dev/null || true
    update-rc.d conduit remove 2>/dev/null || true
    chkconfig conduit off 2>/dev/null || true
    rm -f /etc/init.d/conduit
    
    log_info "Removing configuration files..."
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/conduit
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ UNINSTALL COMPLETE!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Conduit and all related components have been removed."
    echo ""
    echo "Note: Docker itself was NOT removed."
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Main
#═══════════════════════════════════════════════════════════════════════

show_usage() {
    echo "Psiphon Conduit Manager v${VERSION}"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (no args)      Install or open management menu if already installed"
    echo "  --reinstall    Force fresh reinstall"
    echo "  --uninstall    Completely remove Conduit and all components"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo bash $0              # Install or open menu"
    echo "  sudo bash $0 --reinstall  # Fresh install"
    echo "  sudo bash $0 --uninstall  # Remove everything"
    echo ""
    echo "After install, use: conduit"
}

main() {
    # Handle command line arguments
    case "${1:-}" in
        --uninstall|-u)
            check_root
            uninstall
            exit 0
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        --reinstall)
            # Force reinstall
            FORCE_REINSTALL=true
            ;;
    esac
    
    print_header
    detect_os
    check_root
    ensure_install_dir_writable
    load_settings
    log_info "Using settings: $INSTALL_DIR/settings.conf"
    
    # Ensure all tools (including new ones like tcpdump) are present
    check_dependencies
    
    # Check if already installed
    if [ -f "$INSTALL_DIR/conduit" ] && [ "$FORCE_REINSTALL" != "true" ]; then
        echo -e "${GREEN}Conduit is already installed!${NC}"
        echo ""
        echo "What would you like to do?"
        echo ""
        echo "  1. 📊 Open management menu"
        echo "  2. 🔄 Reinstall (fresh install)"
        echo "  3. 🗑️  Uninstall"
        echo "  0. 🚪 Exit"
        echo ""
        read -p "  Enter choice: " choice < /dev/tty || true
        
        case $choice in
            1)
                echo -e "${CYAN}Updating management script and opening menu...${NC}"
                create_management_script
                exec "$INSTALL_DIR/conduit" menu
                ;;
            2)
                echo ""
                log_info "Starting fresh reinstall..."
                ;;
            3)
                uninstall
                exit 0
                ;;
            0)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}"
                echo -e "${CYAN}Returning to installer...${NC}"
                sleep 1
                main "$@"
                ;;
        esac
    fi

    # Interactive settings prompt (max-clients, bandwidth)
    prompt_settings

    echo ""
    echo -e "${CYAN}Starting installation...${NC}"
    echo ""

    #───────────────────────────────────────────────────────────────
    # Installation Steps (5 steps if backup exists, otherwise 4)
    #───────────────────────────────────────────────────────────────

    # Step 1: Install Docker (if not already installed)
    log_info "Step 1/5: Installing Docker..."
    install_docker
    ensure_docker_running

    echo ""

    # Step 2: Check for and optionally restore backup keys
    # This preserves node identity if user had a previous installation
    log_info "Step 2/5: Checking for previous node identity..."
    check_and_offer_backup_restore

    echo ""

    # Step 3: Start Conduit container
    log_info "Step 3/5: Starting Conduit..."
    run_conduit
    
    echo ""

    # Step 4: Save settings and configure auto-start service
    log_info "Step 4/5: Setting up auto-start..."
    save_settings
    setup_autostart
    setup_tracker_service

    echo ""

    # Step 5: Create the 'conduit' CLI management script
    log_info "Step 5/5: Creating management script..."
    create_management_script

    print_summary

    read -p "Open management menu now? [Y/n] " open_menu < /dev/tty || true
    if [[ ! "$open_menu" =~ ^[Nn] ]]; then
        exec "$INSTALL_DIR/conduit" menu
    fi

    exit 0
}
#
# REACHED END OF SCRIPT - VERSION 1.1.0
# ###############################################################################
main "$@"
