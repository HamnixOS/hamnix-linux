#!/bin/bash
# BrainhairOS Comprehensive Test Suite
# Tests compiler, userland utilities, kernel, and networking

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
SKIPPED=0

# Project root
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Test result tracking
pass() {
    echo -e "  ${GREEN}PASS${NC}: $1"
    ((PASSED++))
}

fail() {
    echo -e "  ${RED}FAIL${NC}: $1"
    ((FAILED++))
}

skip() {
    echo -e "  ${YELLOW}SKIP${NC}: $1"
    ((SKIPPED++))
}

section() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
}

# =============================================================================
# Toolchain Tests
# =============================================================================
test_toolchain() {
    section "Toolchain Tests"

    # Test compiler exists and runs
    if python3 compiler/brainhair.py --help >/dev/null 2>&1; then
        pass "Brainhair compiler runs"
    else
        fail "Brainhair compiler failed to run"
    fi

    # Test self-hosted compiler exists
    if [ -x bin/bhc ]; then
        pass "Self-hosted compiler exists"
    else
        skip "Self-hosted compiler not built"
    fi

    # Test self-hosted assembler exists
    if [ -x bin/basm ]; then
        pass "Self-hosted assembler exists"
    else
        skip "Self-hosted assembler not built"
    fi

    # Test self-hosted linker exists
    if [ -x bin/bhlink ]; then
        pass "Self-hosted linker exists"
    else
        skip "Self-hosted linker not built"
    fi

    # Test bhbuild build script exists
    if [ -x bin/bhbuild ]; then
        pass "Build script (bhbuild) exists"
    else
        skip "Build script not built"
    fi

    # Test NASM is available
    if command -v nasm >/dev/null 2>&1; then
        pass "NASM assembler available"
    else
        fail "NASM not installed"
    fi
}

# =============================================================================
# Compilation Tests
# =============================================================================
test_compilation() {
    section "Compilation Tests"

    # Test compiling a simple program
    echo 'proc main() = discard 0' > /tmp/test_simple.bh
    if python3 compiler/brainhair.py /tmp/test_simple.bh -o /tmp/test_simple >/dev/null 2>&1; then
        pass "Simple program compiles"
        rm -f /tmp/test_simple.bh /tmp/test_simple.asm /tmp/test_simple.o
    else
        fail "Simple program compilation failed"
    fi

    # Test compiling with syscalls
    cat > /tmp/test_syscall.bh << 'EOF'
import "lib/syscalls"
proc main() =
    discard syscall1(SYS_exit, 42)
EOF
    if python3 compiler/brainhair.py /tmp/test_syscall.bh -o /tmp/test_syscall >/dev/null 2>&1; then
        pass "Program with syscalls compiles"
        rm -f /tmp/test_syscall.bh /tmp/test_syscall.asm /tmp/test_syscall.o
    else
        fail "Syscall program compilation failed"
    fi

    # Test kernel module compilation
    if python3 compiler/brainhair.py kernel/kernel_main.bh --kernel -o /tmp/kernel_test >/dev/null 2>&1; then
        pass "Kernel module compiles"
        rm -f /tmp/kernel_test.asm /tmp/kernel_test.o
    else
        fail "Kernel module compilation failed"
    fi

    # Test syscalls.asm with NASM
    if nasm -f elf32 lib/syscalls.asm -o /tmp/syscalls_test.o 2>/dev/null; then
        pass "syscalls.asm assembles with NASM"
        rm -f /tmp/syscalls_test.o
    else
        fail "syscalls.asm assembly failed"
    fi
}

# =============================================================================
# Userland Utility Tests
# =============================================================================
test_userland_utilities() {
    section "Userland Utility Tests"

    # Test echo
    if [ -x bin/echo ]; then
        OUTPUT=$(./bin/echo "hello world" 2>&1)
        if [ "$OUTPUT" = "hello world" ]; then
            pass "echo utility works"
        else
            fail "echo utility output incorrect: $OUTPUT"
        fi
    else
        skip "echo not built"
    fi

    # Test true
    if [ -x bin/true ]; then
        if ./bin/true; then
            pass "true returns 0"
        else
            fail "true returned non-zero"
        fi
    else
        skip "true not built"
    fi

    # Test false
    if [ -x bin/false ]; then
        if ./bin/false; then
            fail "false returned 0"
        else
            pass "false returns 1"
        fi
    else
        skip "false not built"
    fi

    # Test cat
    if [ -x bin/cat ]; then
        echo "test content" > /tmp/test_cat.txt
        OUTPUT=$(./bin/cat /tmp/test_cat.txt 2>&1)
        if [ "$OUTPUT" = "test content" ]; then
            pass "cat utility works"
        else
            fail "cat utility output incorrect"
        fi
        rm -f /tmp/test_cat.txt
    else
        skip "cat not built"
    fi

    # Test wc
    if [ -x bin/wc ]; then
        echo -e "line1\nline2\nline3" > /tmp/test_wc.txt
        OUTPUT=$(./bin/wc /tmp/test_wc.txt 2>&1)
        if echo "$OUTPUT" | grep -q "3"; then
            pass "wc counts lines"
        else
            fail "wc line count incorrect"
        fi
        rm -f /tmp/test_wc.txt
    else
        skip "wc not built"
    fi

    # Test head
    if [ -x bin/head ]; then
        seq 1 20 > /tmp/test_head.txt
        OUTPUT=$(./bin/head -n 5 /tmp/test_head.txt 2>&1 | wc -l)
        if [ "$OUTPUT" -le 5 ]; then
            pass "head limits output"
        else
            fail "head output too long"
        fi
        rm -f /tmp/test_head.txt
    else
        skip "head not built"
    fi

    # Test tail
    if [ -x bin/tail ]; then
        seq 1 20 > /tmp/test_tail.txt
        OUTPUT=$(./bin/tail -n 5 /tmp/test_tail.txt 2>&1 | wc -l)
        if [ "$OUTPUT" -le 5 ]; then
            pass "tail limits output"
        else
            fail "tail output too long"
        fi
        rm -f /tmp/test_tail.txt
    else
        skip "tail not built"
    fi

    # Test uname
    if [ -x bin/uname ]; then
        OUTPUT=$(./bin/uname 2>&1)
        if [ -n "$OUTPUT" ]; then
            pass "uname returns output"
        else
            fail "uname returned empty"
        fi
    else
        skip "uname not built"
    fi

    # Test pwd
    if [ -x bin/pwd ]; then
        OUTPUT=$(./bin/pwd 2>&1)
        if [ -n "$OUTPUT" ]; then
            pass "pwd returns current directory"
        else
            fail "pwd returned empty"
        fi
    else
        skip "pwd not built"
    fi

    # Test basename
    if [ -x bin/basename ]; then
        OUTPUT=$(./bin/basename /path/to/file.txt 2>&1)
        if [ "$OUTPUT" = "file.txt" ]; then
            pass "basename extracts filename"
        else
            fail "basename output incorrect: $OUTPUT"
        fi
    else
        skip "basename not built"
    fi

    # Test dirname
    if [ -x bin/dirname ]; then
        OUTPUT=$(./bin/dirname /path/to/file.txt 2>&1)
        if [ "$OUTPUT" = "/path/to" ]; then
            pass "dirname extracts directory"
        else
            fail "dirname output incorrect: $OUTPUT"
        fi
    else
        skip "dirname not built"
    fi

    # Test seq
    if [ -x bin/seq ]; then
        OUTPUT=$(./bin/seq 1 5 2>&1 | wc -l)
        if [ "$OUTPUT" -eq 5 ]; then
            pass "seq generates sequence"
        else
            fail "seq output incorrect count: $OUTPUT"
        fi
    else
        skip "seq not built"
    fi

    # Test rev
    if [ -x bin/rev ]; then
        echo "hello" > /tmp/test_rev.txt
        OUTPUT=$(./bin/rev /tmp/test_rev.txt 2>&1)
        if [ "$OUTPUT" = "olleh" ]; then
            pass "rev reverses string"
        else
            fail "rev output incorrect: $OUTPUT"
        fi
        rm -f /tmp/test_rev.txt
    else
        skip "rev not built"
    fi

    # Test expr
    if [ -x bin/expr ]; then
        OUTPUT=$(./bin/expr 2 + 3 2>&1)
        if [ "$OUTPUT" = "5" ]; then
            pass "expr evaluates arithmetic"
        else
            fail "expr output incorrect: $OUTPUT"
        fi
    else
        skip "expr not built"
    fi

    # Test factor
    if [ -x bin/factor ]; then
        OUTPUT=$(./bin/factor 12 2>&1)
        if echo "$OUTPUT" | grep -q "2" && echo "$OUTPUT" | grep -q "3"; then
            pass "factor finds prime factors"
        else
            fail "factor output incorrect: $OUTPUT"
        fi
    else
        skip "factor not built"
    fi
}

# =============================================================================
# File Operation Tests
# =============================================================================
test_file_operations() {
    section "File Operation Tests"

    TESTDIR="/tmp/brainhair_test_$$"
    mkdir -p "$TESTDIR"

    # Test mkdir
    if [ -x bin/mkdir ]; then
        ./bin/mkdir "$TESTDIR/newdir" 2>/dev/null
        if [ -d "$TESTDIR/newdir" ]; then
            pass "mkdir creates directory"
        else
            fail "mkdir failed to create directory"
        fi
    else
        skip "mkdir not built"
    fi

    # Test touch
    if [ -x bin/touch ]; then
        ./bin/touch "$TESTDIR/newfile" 2>/dev/null
        if [ -f "$TESTDIR/newfile" ]; then
            pass "touch creates file"
        else
            fail "touch failed to create file"
        fi
    else
        skip "touch not built"
    fi

    # Test cp
    if [ -x bin/cp ]; then
        echo "content" > "$TESTDIR/source"
        ./bin/cp "$TESTDIR/source" "$TESTDIR/dest" 2>/dev/null
        if [ -f "$TESTDIR/dest" ]; then
            pass "cp copies file"
        else
            fail "cp failed to copy file"
        fi
    else
        skip "cp not built"
    fi

    # Test mv
    if [ -x bin/mv ]; then
        echo "content" > "$TESTDIR/moveme"
        ./bin/mv "$TESTDIR/moveme" "$TESTDIR/moved" 2>/dev/null
        if [ -f "$TESTDIR/moved" ] && [ ! -f "$TESTDIR/moveme" ]; then
            pass "mv moves file"
        else
            fail "mv failed to move file"
        fi
    else
        skip "mv not built"
    fi

    # Test rm
    if [ -x bin/rm ]; then
        echo "delete me" > "$TESTDIR/deleteme"
        ./bin/rm "$TESTDIR/deleteme" 2>/dev/null
        if [ ! -f "$TESTDIR/deleteme" ]; then
            pass "rm removes file"
        else
            fail "rm failed to remove file"
        fi
    else
        skip "rm not built"
    fi

    # Test ln (symbolic link)
    if [ -x bin/ln ]; then
        echo "target" > "$TESTDIR/linktarget"
        ./bin/ln -s "$TESTDIR/linktarget" "$TESTDIR/symlink" 2>/dev/null
        if [ -L "$TESTDIR/symlink" ]; then
            pass "ln creates symbolic link"
        else
            fail "ln failed to create symlink"
        fi
    else
        skip "ln not built"
    fi

    # Cleanup
    rm -rf "$TESTDIR"
}

# =============================================================================
# Build System Tests
# =============================================================================
test_build_system() {
    section "Build System Tests"

    # Test Makefile exists
    if [ -f Makefile ]; then
        pass "Makefile exists"
    else
        fail "Makefile not found"
    fi

    # Test build directory creation
    if make $(BUILD_DIR) >/dev/null 2>&1 || [ -d build ]; then
        pass "Build directory exists"
    else
        skip "Build directory not created"
    fi

    # Test clean target
    if make -n clean >/dev/null 2>&1; then
        pass "Clean target exists"
    else
        fail "Clean target missing"
    fi

    # Test userland target exists
    if make -n userland >/dev/null 2>&1; then
        pass "Userland target exists"
    else
        fail "Userland target missing"
    fi

    # Test microkernel target exists
    if make -n microkernel >/dev/null 2>&1; then
        pass "Microkernel target exists"
    else
        fail "Microkernel target missing"
    fi
}

# =============================================================================
# Library Tests
# =============================================================================
test_libraries() {
    section "Library Tests"

    # Test syscalls library exists
    if [ -f lib/syscalls.bh ]; then
        pass "Syscalls library exists"
    else
        fail "Syscalls library missing"
    fi

    # Test syscalls.asm exists
    if [ -f lib/syscalls.asm ]; then
        pass "Syscalls assembly exists"
    else
        fail "Syscalls assembly missing"
    fi

    # Test net library exists
    if [ -f lib/net.bh ]; then
        pass "Network library exists"
    else
        fail "Network library missing"
    fi

    # Test flask library exists
    if [ -f lib/flask.bh ]; then
        pass "Flask library exists"
    else
        fail "Flask library missing"
    fi

    # Test gui library exists
    if [ -f lib/gui.bh ]; then
        pass "GUI library exists"
    else
        fail "GUI library missing"
    fi

    # Test syscalls.o can be built
    if nasm -f elf32 lib/syscalls.asm -o /tmp/test_syscalls.o 2>/dev/null; then
        # Check for required symbols
        if nm /tmp/test_syscalls.o 2>/dev/null | grep -q "syscall1"; then
            pass "syscalls.o has syscall1"
        else
            fail "syscalls.o missing syscall1"
        fi
        if nm /tmp/test_syscalls.o 2>/dev/null | grep -q "call_handler"; then
            pass "syscalls.o has call_handler"
        else
            fail "syscalls.o missing call_handler"
        fi
        rm -f /tmp/test_syscalls.o
    else
        fail "Failed to build syscalls.o"
    fi
}

# =============================================================================
# Kernel Source Tests
# =============================================================================
test_kernel_sources() {
    section "Kernel Source Tests"

    # Test kernel_main.bh exists
    if [ -f kernel/kernel_main.bh ]; then
        pass "Kernel main source exists"
    else
        fail "Kernel main source missing"
    fi

    # Test boot assembly files
    for asm in boot/stage1.asm boot/stage2.asm boot/boot.asm; do
        if [ -f "$asm" ]; then
            pass "$asm exists"
        else
            fail "$asm missing"
        fi
    done

    # Test kernel assembly files
    for asm in kernel/idt.asm kernel/isr.asm kernel/paging.asm kernel/process.asm kernel/elf.asm kernel/net.asm; do
        if [ -f "$asm" ]; then
            pass "$asm exists"
        else
            fail "$asm missing"
        fi
    done

    # Test linker script exists
    if [ -f boot/linker.ld ]; then
        pass "Linker script exists"
    else
        fail "Linker script missing"
    fi
}

# =============================================================================
# QEMU Integration Tests (if available)
# =============================================================================
test_qemu_integration() {
    section "QEMU Integration Tests"

    # Check if QEMU is available
    if ! command -v qemu-system-i386 >/dev/null 2>&1; then
        skip "QEMU not installed"
        return
    fi

    # Check if kernel image exists
    if [ ! -f build/brainhair.img ]; then
        skip "Disk image not built (run 'make microkernel-uweb' first)"
        return
    fi

    # Test kernel boots and reaches shell prompt
    echo "  Testing kernel boot (10 second timeout)..."

    LOGFILE="/tmp/qemu_boot_test_$$.log"
    timeout 10 qemu-system-i386 \
        -drive file=build/brainhair.img,format=raw \
        -device e1000,netdev=net0 \
        -netdev user,id=net0 \
        -display none \
        -serial file:$LOGFILE \
        2>/dev/null &
    QEMU_PID=$!

    sleep 8
    kill $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true

    if [ -f "$LOGFILE" ]; then
        if grep -q "BrainhairOS Microkernel" "$LOGFILE"; then
            pass "Kernel banner displayed"
        else
            fail "Kernel banner not found"
        fi

        if grep -q "\[OK\] IDT initialized" "$LOGFILE"; then
            pass "IDT initialization"
        else
            fail "IDT initialization failed"
        fi

        if grep -q "\[OK\] Paging enabled" "$LOGFILE"; then
            pass "Paging enabled"
        else
            fail "Paging not enabled"
        fi

        if grep -q "\[OK\] Network:" "$LOGFILE"; then
            pass "Network driver initialized"
        else
            fail "Network driver failed"
        fi

        if grep -q "\[OK\] IP:" "$LOGFILE"; then
            pass "DHCP acquired IP address"
        else
            fail "DHCP failed"
        fi

        if grep -q "Running on http://0.0.0.0:8080" "$LOGFILE"; then
            pass "Flask webapp started"
        else
            fail "Flask webapp did not start"
        fi

        rm -f "$LOGFILE"
    else
        fail "No QEMU output captured"
    fi
}

# =============================================================================
# HTTP Server Test
# =============================================================================
test_http_server() {
    section "HTTP Server Tests"

    # Check if QEMU is available
    if ! command -v qemu-system-i386 >/dev/null 2>&1; then
        skip "QEMU not installed"
        return
    fi

    # Check if curl is available
    if ! command -v curl >/dev/null 2>&1; then
        skip "curl not installed"
        return
    fi

    # Check if kernel image exists
    if [ ! -f build/brainhair.img ]; then
        skip "Disk image not built"
        return
    fi

    echo "  Starting QEMU with HTTP server (15 second test)..."

    LOGFILE="/tmp/qemu_http_test_$$.log"
    qemu-system-i386 \
        -drive file=build/brainhair.img,format=raw \
        -device e1000,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::18080-:8080 \
        -display none \
        -serial file:$LOGFILE \
        2>/dev/null &
    QEMU_PID=$!

    # Wait for server to start
    sleep 8

    # Test HTTP request
    RESPONSE=$(curl -s --max-time 5 http://localhost:18080/ 2>/dev/null || echo "CURL_FAILED")

    if [ "$RESPONSE" = "Hello" ]; then
        pass "HTTP GET / returns 'Hello'"
    elif [ "$RESPONSE" = "CURL_FAILED" ]; then
        fail "HTTP request failed (connection refused or timeout)"
    else
        fail "HTTP response incorrect: $RESPONSE"
    fi

    # Cleanup
    kill $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true
    rm -f "$LOGFILE"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${BLUE}BrainhairOS Test Suite${NC}"
    echo "========================"

    # Parse arguments
    QUICK=0
    for arg in "$@"; do
        case $arg in
            --quick|-q)
                QUICK=1
                ;;
            --help|-h)
                echo "Usage: $0 [--quick|-q] [--help|-h]"
                echo "  --quick, -q  Skip slow QEMU tests"
                echo "  --help, -h   Show this help"
                exit 0
                ;;
        esac
    done

    test_toolchain
    test_compilation
    test_userland_utilities
    test_file_operations
    test_build_system
    test_libraries
    test_kernel_sources

    if [ "$QUICK" -eq 0 ]; then
        test_qemu_integration
        test_http_server
    else
        section "QEMU Tests"
        skip "Skipped (use without --quick to run)"
    fi

    # Summary
    echo ""
    echo -e "${BLUE}=== Test Summary ===${NC}"
    echo -e "  ${GREEN}Passed${NC}: $PASSED"
    echo -e "  ${RED}Failed${NC}: $FAILED"
    echo -e "  ${YELLOW}Skipped${NC}: $SKIPPED"
    echo ""

    if [ $FAILED -gt 0 ]; then
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
