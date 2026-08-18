#!/bin/bash
#
# NOT REGISTERED, AND IT WAS RUN FIRST -- ITS PASS IS OVER AN EMPTY SET. This
# gate is not in ci_battery_manifest.txt because, RUN on this tree on
# 2026-08-18, its whole output was:
#
#     [task_fd_loops] SKIP: arch/x86/kernel/syscall.ad not found
#     [task_fd_loops] SKIP: sys/src/9/port/sysproc.ad not found
#     [task_fd_loops] PASS: no hardcoded-literal task/fd-table loops
#
# Neither file is in this repository, so the PASS is over nothing at all. An
# assertion that cannot fail is not an assertion. It belongs to the kernel
# repository's battery.
# Regression guard for the 2026-06-17 capacity-bump bug cluster.
#
# The global task table (sized NTASKS) and the per-task fd table (sized
# NR_FDS) must NEVER be iterated with a hardcoded LITERAL bound. When the
# capacity constants were bumped (NTASKS 64->256, NR_FDS->64), five loops
# in syscall.ad + two in sysproc.ad still scanned only the first 16 slots
# (`while i < 16`), silently:
#   - dropping fds 16..NR_FDS-1 across fork()/thread spawn, and
#   - making children in task slots 16..NTASKS-1 unwaitable / unreapable.
# (Fixed in 2b0a9a47 + 119cbf4c: bound by NTASKS / NR_FDS.)
#
# This grep guard fails if any process-management loop indexes the task
# table (task_struct_at) or fd table (dup_fd_to_child) with a literal-
# bounded loop variable again. It is a pure source check — no build/boot.

set -u
cd "$(dirname "$0")/.." || exit 2

FILES="arch/x86/kernel/syscall.ad sys/src/9/port/sysproc.ad"
fail=0

for f in $FILES; do
    if [ ! -f "$f" ]; then
        echo "[task_fd_loops] SKIP: $f not found"
        continue
    fi
    # A 'while <var> < <digit...>' header whose next 2 lines index the task
    # table or fd table by the loop variable = a literal-bounded task/fd
    # loop. After the fix these all read 'while i < NTASKS' / '< NR_FDS',
    # so the expected match count is ZERO.
    hits=$(grep -nA2 -E 'while[[:space:]]+[a-z_][a-z0-9_]*[[:space:]]*<[[:space:]]*[0-9]' "$f" \
        | grep -E 'task_struct_at\(cast\[int32\]\(|dup_fd_to_child\(' || true)
    if [ -n "$hits" ]; then
        echo "[task_fd_loops] FAIL: hardcoded-literal task/fd loop in $f:"
        echo "$hits" | sed 's/^/    /'
        echo "    -> bound these by NTASKS / NR_FDS, not a literal."
        fail=1
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "[task_fd_loops] PASS: no hardcoded-literal task/fd-table loops"
    exit 0
fi
exit 1
