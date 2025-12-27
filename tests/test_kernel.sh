#!/bin/bash
# BrainhairOS Kernel Boot Test
# Tests kernel boot sequence in QEMU

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; ((PASSED++)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; ((FAILED++)); }

echo ""
echo -e "${BLUE}BrainhairOS Kernel Boot Test${NC}"
echo "=============================="

# Check prerequisites
if ! command -v qemu-system-i386 >/dev/null 2>&1; then
    echo -e "${RED}Error: qemu-system-i386 not installed${NC}"
    exit 1
fi

if [ ! -f build/brainhair.img ]; then
    echo -e "${YELLOW}Building kernel image...${NC}"
    make microkernel-uweb >/dev/null 2>&1 || {
        echo -e "${RED}Error: Failed to build kernel${NC}"
        exit 1
    }
fi

echo ""
echo "Starting QEMU (10 second timeout)..."

LOGFILE="/tmp/kernel_boot_test_$$.log"

# Start QEMU in background
timeout 12 qemu-system-i386 \
    -drive file=build/brainhair.img,format=raw \
    -device e1000,netdev=net0 \
    -netdev user,id=net0 \
    -display none \
    -serial file:$LOGFILE \
    2>/dev/null &
QEMU_PID=$!

# Wait for boot
sleep 10

# Terminate QEMU
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

echo ""
echo -e "${BLUE}=== Boot Sequence Checks ===${NC}"

if [ ! -f "$LOGFILE" ]; then
    fail "No output captured from QEMU"
    exit 1
fi

# Check boot stages
check_log() {
    local pattern=$1
    local desc=$2
    if grep -q "$pattern" "$LOGFILE"; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

check_log "BrainhairOS Microkernel" "Kernel banner displayed"
check_log "\[OK\] IDT initialized" "IDT initialization"
check_log "\[OK\] Paging enabled" "Paging enabled"
check_log "\[OK\] Scheduler initialized" "Scheduler initialization"
check_log "\[OK\] Interrupts enabled" "Interrupts enabled"
check_log "\[OK\] Keyboard initialized" "Keyboard driver"
check_log "\[OK\] Ramdisk initialized" "Ramdisk initialization"
check_log "\[OK\] Network:" "Network driver (MAC address)"
check_log "\[OK\] IP:" "DHCP IP assignment"
check_log "Loading userland webapp" "Userland ELF loading"
check_log "Entry point:" "ELF entry point found"
check_log "\[Flask\] route /" "Flask routes registered"
check_log "Running on http://0.0.0.0:8080" "HTTP server started"
check_log "\[TCP\] Listen on port" "TCP listener created"

echo ""
echo -e "${BLUE}=== Network Initialization ===${NC}"

# Check DHCP sequence
check_log "\[DHCP\]" "DHCP discovery started"
check_log "Offer:" "DHCP offer received"
check_log "Bound:" "DHCP bound"

echo ""
echo -e "${BLUE}=== TCP Stack ===${NC}"

# If we received any connections during boot
if grep -q "SYN" "$LOGFILE"; then
    check_log "SYN-ACK" "TCP SYN-ACK sent"
fi

# Cleanup
rm -f "$LOGFILE"

# Summary
echo ""
echo -e "${BLUE}=== Test Summary ===${NC}"
echo -e "  ${GREEN}Passed${NC}: $PASSED"
echo -e "  ${RED}Failed${NC}: $FAILED"
echo ""

[ $FAILED -eq 0 ] && echo -e "${GREEN}Kernel boot test passed!${NC}" && exit 0
echo -e "${RED}Kernel boot test failed!${NC}" && exit 1
