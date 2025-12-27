#!/bin/bash
# BrainhairOS HTTP Server Test
# Tests HTTP server functionality

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
echo -e "${BLUE}BrainhairOS HTTP Server Test${NC}"
echo "=============================="

# Check prerequisites
if ! command -v qemu-system-i386 >/dev/null 2>&1; then
    echo -e "${RED}Error: qemu-system-i386 not installed${NC}"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}Error: curl not installed${NC}"
    exit 1
fi

if [ ! -f build/brainhair.img ]; then
    echo -e "${YELLOW}Building kernel image...${NC}"
    make microkernel-uweb >/dev/null 2>&1 || {
        echo -e "${RED}Error: Failed to build kernel${NC}"
        exit 1
    }
fi

# Find an available port
PORT=18080
while netstat -tuln 2>/dev/null | grep -q ":$PORT " || ss -tuln 2>/dev/null | grep -q ":$PORT "; do
    ((PORT++))
    if [ $PORT -gt 19000 ]; then
        echo -e "${RED}Error: No available ports${NC}"
        exit 1
    fi
done
echo "Using port $PORT for host forwarding"

echo ""
echo "Starting QEMU with HTTP server..."

LOGFILE="/tmp/http_test_$$.log"

# Start QEMU in background
qemu-system-i386 \
    -drive file=build/brainhair.img,format=raw \
    -device e1000,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::$PORT-:8080 \
    -display none \
    -serial file:$LOGFILE \
    2>/dev/null &
QEMU_PID=$!

cleanup() {
    kill $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true
    rm -f "$LOGFILE"
}
trap cleanup EXIT

# Wait for server to start
echo "Waiting for HTTP server to start..."
sleep 10

echo ""
echo -e "${BLUE}=== HTTP Request Tests ===${NC}"

# Test 1: GET /
echo "Testing GET /..."
RESPONSE=$(curl -s --max-time 5 "http://localhost:$PORT/" 2>/dev/null) || RESPONSE="TIMEOUT"
if [ "$RESPONSE" = "Hello" ]; then
    pass "GET / returns 'Hello'"
elif [ "$RESPONSE" = "TIMEOUT" ]; then
    fail "GET / timed out"
else
    fail "GET / unexpected response: '$RESPONSE'"
fi

# Note: Due to QEMU SLiRP NAT limitations, subsequent requests may fail
# This is a known limitation documented in the codebase

echo ""
echo -e "${BLUE}=== QEMU Serial Log Analysis ===${NC}"

if [ -f "$LOGFILE" ]; then
    if grep -q "\[Flask\] accept ready" "$LOGFILE"; then
        pass "Flask accepted connection"
    else
        fail "Flask did not accept connection"
    fi

    if grep -q "\[Flask\] recv n=" "$LOGFILE"; then
        pass "Flask received request data"
    else
        fail "Flask did not receive data"
    fi

    if grep -q "\[Flask\] route_idx=" "$LOGFILE"; then
        pass "Flask found matching route"
    else
        fail "Flask route matching failed"
    fi

    if grep -q "\[TCP\] write conn=" "$LOGFILE"; then
        pass "TCP sent response"
    else
        fail "TCP did not send response"
    fi
fi

# Summary
echo ""
echo -e "${BLUE}=== Test Summary ===${NC}"
echo -e "  ${GREEN}Passed${NC}: $PASSED"
echo -e "  ${RED}Failed${NC}: $FAILED"
echo ""

echo -e "${YELLOW}Note: QEMU SLiRP NAT has limitations with rapid port reuse.${NC}"
echo -e "${YELLOW}First request typically works; subsequent may timeout.${NC}"
echo ""

[ $FAILED -eq 0 ] && echo -e "${GREEN}HTTP server test passed!${NC}" && exit 0
echo -e "${RED}HTTP server test had failures${NC}" && exit 1
