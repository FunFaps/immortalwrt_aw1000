#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEED="$SCRIPT_DIR/nss-setup/config-aw1000.seed"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

usage() {
    cat <<'USAGE'
Usage: ./setup-aw1000.sh [OPTIONS]

Prepare ImmortalWrt build environment for Arcadyan AW1000 with NSS offloading.

Options:
  --clean       Run 'make clean' before setup
  --full-clean  Run 'make dirclean' (removes toolchain + build dirs)
  --feeds       Update and install feeds
  --menuconfig  Open menuconfig after setup
  --build       Start build after setup
  --jobs N      Number of parallel jobs for build (default: nproc)
  -h, --help    Show this help

Examples:
  ./setup-aw1000.sh                    # Just prepare .config
  ./setup-aw1000.sh --feeds            # Update feeds + prepare .config
  ./setup-aw1000.sh --feeds --build    # Full pipeline: feeds + config + build
  ./setup-aw1000.sh --clean --build    # Clean + config + build
USAGE
    exit 0
}

DO_CLEAN=0
DO_DIRCLEAN=0
DO_FEEDS=0
DO_MENUCONFIG=0
DO_BUILD=0
JOBS=$(nproc 2>/dev/null || echo 4)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)      DO_CLEAN=1 ;;
        --full-clean) DO_DIRCLEAN=1 ;;
        --feeds)      DO_FEEDS=1 ;;
        --menuconfig) DO_MENUCONFIG=1 ;;
        --build)      DO_BUILD=1 ;;
        --jobs)       shift; JOBS="$1" ;;
        -h|--help)    usage ;;
        *)            err "Unknown option: $1. Use --help for usage." ;;
    esac
    shift
done

cd "$SCRIPT_DIR"

if [[ ! -f "Makefile" ]] || [[ ! -d "target/linux" ]]; then
    err "Must be run from ImmortalWrt root directory"
fi

if [[ ! -f "$SEED" ]]; then
    err "Seed config not found: $SEED"
fi

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  AW1000 NSS Build Setup${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# --- Clean ---
if [[ $DO_DIRCLEAN -eq 1 ]]; then
    info "Running make dirclean..."
    make dirclean
    ok "dirclean complete"
elif [[ $DO_CLEAN -eq 1 ]]; then
    info "Running make clean..."
    make clean
    ok "clean complete"
fi

# --- Feeds ---
if [[ $DO_FEEDS -eq 1 ]]; then
    info "Updating feeds..."
    ./scripts/feeds update -a
    ok "Feeds updated"

    info "Installing feeds..."
    ./scripts/feeds install -a
    ok "Feeds installed"
fi

# --- Config ---
info "Applying seed config from nss-setup/config-aw1000.seed"

if [[ -f ".config" ]]; then
    BACKUP=".config.bak.$(date +%Y%m%d_%H%M%S)"
    warn "Existing .config backed up to $BACKUP"
    cp .config "$BACKUP"
fi

cp "$SEED" .config

info "Running make defconfig..."
make defconfig

# --- Verify NSS ---
echo ""
info "Verifying NSS configuration..."

CHECKS=(
    "CONFIG_ATH11K_NSS_SUPPORT=y"
    "CONFIG_PACKAGE_kmod-qca-nss-drv=y"
    "CONFIG_PACKAGE_kmod-qca-nss-ecm=y"
    "CONFIG_NSS_DRV_BRIDGE_ENABLE=y"
    "CONFIG_PACKAGE_kmod-qca-mcs=y"
)

ALL_OK=1
for check in "${CHECKS[@]}"; do
    if grep -q "^${check}$" .config; then
        ok "$check"
    else
        warn "MISSING: $check"
        ALL_OK=0
    fi
done

echo ""
if [[ $ALL_OK -eq 1 ]]; then
    ok "All NSS options verified successfully"
else
    warn "Some NSS options were not set. Check feed installation."
    warn "Try: ./scripts/feeds update -a && ./scripts/feeds install -a"
fi

# --- NSS DRV flags count ---
DRV_COUNT=$(grep -c "^CONFIG_NSS_DRV_.*=y" .config 2>/dev/null || echo 0)
info "NSS firmware feature flags enabled: $DRV_COUNT"

# --- menuconfig ---
if [[ $DO_MENUCONFIG -eq 1 ]]; then
    echo ""
    info "Opening menuconfig..."
    make menuconfig
fi

# --- Build ---
if [[ $DO_BUILD -eq 1 ]]; then
    echo ""
    info "Starting build with $JOBS jobs..."
    LOGFILE="build_$(date +%Y%m%d_%H%M%S).log"
    info "Log file: $LOGFILE"
    echo ""

    make -j"$JOBS" V=s 2>&1 | tee "$LOGFILE"
    EXIT_CODE=${PIPESTATUS[0]}

    echo ""
    if [[ $EXIT_CODE -eq 0 ]]; then
        ok "Build completed successfully!"
        echo ""
        info "Firmware images:"
        ls -lh bin/targets/qualcommax/ipq807x/*aw1000* 2>/dev/null || warn "No AW1000 images found"
    else
        err "Build failed with exit code $EXIT_CODE. Check $LOGFILE"
    fi
else
    echo ""
    ok "Configuration ready!"
    echo ""
    info "Next steps:"
    echo "  1. (Optional) make menuconfig    — customize packages"
    echo "  2. make -j\$(nproc) V=s           — start build"
    echo ""
    info "Or re-run with --build flag:"
    echo "  ./setup-aw1000.sh --build"
fi
