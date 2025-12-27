#!/bin/bash
# BrainhairOS Userland Utility Test Suite
# Tests individual userland utilities for correct behavior

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; ((PASSED++)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1 - $2"; ((FAILED++)); }
skip() { echo -e "  ${YELLOW}SKIP${NC}: $1"; ((SKIPPED++)); }

test_utility() {
    local name=$1
    local args=$2
    local expected=$3
    local input=$4

    if [ ! -x "bin/$name" ]; then
        skip "$name (not built)"
        return
    fi

    if [ -n "$input" ]; then
        OUTPUT=$(echo "$input" | ./bin/$name $args 2>&1) || true
    else
        OUTPUT=$(./bin/$name $args 2>&1) || true
    fi

    if [ "$OUTPUT" = "$expected" ]; then
        pass "$name $args"
    else
        fail "$name $args" "expected '$expected', got '$OUTPUT'"
    fi
}

test_exit_code() {
    local name=$1
    local expected=$2

    if [ ! -x "bin/$name" ]; then
        skip "$name (not built)"
        return
    fi

    ./bin/$name >/dev/null 2>&1
    local code=$?

    if [ "$code" -eq "$expected" ]; then
        pass "$name exit code = $expected"
    else
        fail "$name exit code" "expected $expected, got $code"
    fi
}

echo ""
echo -e "${BLUE}BrainhairOS Userland Utility Tests${NC}"
echo "===================================="

echo ""
echo -e "${BLUE}=== Core Utilities ===${NC}"
test_utility "echo" "hello" "hello"
test_utility "echo" "hello world" "hello world"
test_utility "echo" "-n test" "test"
test_exit_code "true" 0
test_exit_code "false" 1

echo ""
echo -e "${BLUE}=== Text Processing ===${NC}"
test_utility "basename" "/path/to/file.txt" "file.txt"
test_utility "basename" "/path/to/dir/" "dir"
test_utility "dirname" "/path/to/file.txt" "/path/to"
test_utility "dirname" "/path/to/" "/path"

# Test rev
if [ -x bin/rev ]; then
    echo "hello" > /tmp/test_rev.txt
    OUTPUT=$(./bin/rev /tmp/test_rev.txt 2>&1)
    if [ "$OUTPUT" = "olleh" ]; then
        pass "rev reverses text"
    else
        fail "rev" "expected 'olleh', got '$OUTPUT'"
    fi
    rm -f /tmp/test_rev.txt
else
    skip "rev (not built)"
fi

echo ""
echo -e "${BLUE}=== Arithmetic Utilities ===${NC}"
test_utility "expr" "2 + 3" "5"
test_utility "expr" "10 - 4" "6"
test_utility "expr" "3 \\* 4" "12"
test_utility "expr" "15 / 3" "5"

if [ -x bin/seq ]; then
    OUTPUT=$(./bin/seq 1 3 2>&1)
    EXPECTED=$'1\n2\n3'
    if [ "$OUTPUT" = "$EXPECTED" ]; then
        pass "seq 1 3"
    else
        fail "seq 1 3" "output mismatch"
    fi
else
    skip "seq (not built)"
fi

echo ""
echo -e "${BLUE}=== File Information ===${NC}"
if [ -x bin/wc ]; then
    echo -e "one\ntwo\nthree" > /tmp/test_wc.txt
    OUTPUT=$(./bin/wc -l /tmp/test_wc.txt 2>&1)
    if echo "$OUTPUT" | grep -q "3"; then
        pass "wc -l counts lines"
    else
        fail "wc -l" "expected 3 lines"
    fi
    rm -f /tmp/test_wc.txt
else
    skip "wc (not built)"
fi

if [ -x bin/cat ]; then
    echo "test content" > /tmp/test_cat.txt
    OUTPUT=$(./bin/cat /tmp/test_cat.txt 2>&1)
    if [ "$OUTPUT" = "test content" ]; then
        pass "cat reads file"
    else
        fail "cat" "output mismatch"
    fi
    rm -f /tmp/test_cat.txt
else
    skip "cat (not built)"
fi

echo ""
echo -e "${BLUE}=== System Information ===${NC}"
if [ -x bin/uname ]; then
    OUTPUT=$(./bin/uname 2>&1)
    if [ -n "$OUTPUT" ]; then
        pass "uname returns system name"
    else
        fail "uname" "empty output"
    fi
else
    skip "uname (not built)"
fi

if [ -x bin/pwd ]; then
    OUTPUT=$(./bin/pwd 2>&1)
    if [ -n "$OUTPUT" ]; then
        pass "pwd returns directory"
    else
        fail "pwd" "empty output"
    fi
else
    skip "pwd (not built)"
fi

if [ -x bin/hostname ]; then
    OUTPUT=$(./bin/hostname 2>&1)
    if [ -n "$OUTPUT" ]; then
        pass "hostname returns name"
    else
        fail "hostname" "empty output"
    fi
else
    skip "hostname (not built)"
fi

echo ""
echo -e "${BLUE}=== File Operations ===${NC}"
TESTDIR="/tmp/brainhair_userland_test_$$"
mkdir -p "$TESTDIR"

if [ -x bin/touch ]; then
    ./bin/touch "$TESTDIR/newfile" 2>/dev/null
    if [ -f "$TESTDIR/newfile" ]; then
        pass "touch creates file"
    else
        fail "touch" "file not created"
    fi
else
    skip "touch (not built)"
fi

if [ -x bin/mkdir ]; then
    ./bin/mkdir "$TESTDIR/newdir" 2>/dev/null
    if [ -d "$TESTDIR/newdir" ]; then
        pass "mkdir creates directory"
    else
        fail "mkdir" "directory not created"
    fi
else
    skip "mkdir (not built)"
fi

if [ -x bin/cp ]; then
    echo "source content" > "$TESTDIR/src"
    ./bin/cp "$TESTDIR/src" "$TESTDIR/dst" 2>/dev/null
    if [ -f "$TESTDIR/dst" ]; then
        CONTENT=$(cat "$TESTDIR/dst")
        if [ "$CONTENT" = "source content" ]; then
            pass "cp copies file with content"
        else
            fail "cp" "content mismatch"
        fi
    else
        fail "cp" "destination not created"
    fi
else
    skip "cp (not built)"
fi

if [ -x bin/mv ]; then
    echo "move me" > "$TESTDIR/movesrc"
    ./bin/mv "$TESTDIR/movesrc" "$TESTDIR/movedst" 2>/dev/null
    if [ -f "$TESTDIR/movedst" ] && [ ! -f "$TESTDIR/movesrc" ]; then
        pass "mv moves file"
    else
        fail "mv" "move failed"
    fi
else
    skip "mv (not built)"
fi

if [ -x bin/rm ]; then
    echo "delete me" > "$TESTDIR/delme"
    ./bin/rm "$TESTDIR/delme" 2>/dev/null
    if [ ! -f "$TESTDIR/delme" ]; then
        pass "rm removes file"
    else
        fail "rm" "file not removed"
    fi
else
    skip "rm (not built)"
fi

if [ -x bin/rmdir ]; then
    mkdir -p "$TESTDIR/emptydir"
    ./bin/rmdir "$TESTDIR/emptydir" 2>/dev/null
    if [ ! -d "$TESTDIR/emptydir" ]; then
        pass "rmdir removes directory"
    else
        fail "rmdir" "directory not removed"
    fi
else
    skip "rmdir (not built)"
fi

rm -rf "$TESTDIR"

# Summary
echo ""
echo -e "${BLUE}=== Test Summary ===${NC}"
echo -e "  ${GREEN}Passed${NC}: $PASSED"
echo -e "  ${RED}Failed${NC}: $FAILED"
echo -e "  ${YELLOW}Skipped${NC}: $SKIPPED"
echo ""

[ $FAILED -eq 0 ] && exit 0 || exit 1
