/*
 * user/linux-runtime.S — freestanding x86_64 Linux userspace runtime for
 * the `x86_64-linux` Adder target.
 *
 * MIRRORS user/runtime.S (the Hamnix x86 user runtime) and the inline
 * `_start` the aarch64-linux backend emits — but targets the HOST Linux
 * kernel: standard Linux x86_64 syscall numbers (read=0, write=1, open=2,
 * close=3, lseek=8, exit=60) issued via the raw `syscall` instruction. No
 * libc, no C runtime, no Plan 9 / Hamnix kernel. The resulting ELF runs
 * directly on the developer's host Linux kernel.
 *
 * Syscall ABI (System V x86_64 syscall convention):
 *   %rax = syscall number
 *   %rdi, %rsi, %rdx, %r10, %r8, %r9 = args  (arg4 in %r10, NOT %rcx)
 *   return value in %rax
 *
 * The Adder codegen uses the System V *function* call convention
 * (rdi, rsi, rdx, rcx, r8, r9). For the <=3-arg wrappers below the
 * function arg regs (rdi/rsi/rdx) already line up with the syscall arg
 * regs, so each wrapper just loads the number into %rax and issues
 * `syscall`. lseek (3 args) likewise fits without a shuffle.
 *
 * Unlike user/runtime.S this is plain 64-bit code in a real elf64-x86-64
 * object (assembled `as --64`, no `.code64`-in-elf32 wrapper trick). It is
 * preprocessed (`gcc -c -DLINUX_ABI`) so user/syscall_nums.h's named
 * constants resolve.
 */

#define LINUX_ABI
#include "syscall_nums.h"

    /* --- Stack-protector runtime ------------------------------------
     * The Adder x86_64 codegen emits a canary load/store pair (and a
     * tail-call to __stack_chk_fail on mismatch) around every function it
     * tags `needs_canary` — any Array[N] local or `&local`. Both symbols
     * must resolve in every linked binary, so provide weak definitions
     * here; every x86_64-linux ELF pulls in linux-runtime.o. A binary that
     * wants a real PRNG-seeded guard can supply strong definitions.
     *
     * On mismatch, exit(134) — the SIGABRT exit code glibc uses. */
    .section .data
    .align 8
    .weak __stack_chk_guard
__stack_chk_guard:
    .quad 0xC0FFEEDEADBEEFC0

    .text
    .weak __stack_chk_fail
    .type __stack_chk_fail, @function
__stack_chk_fail:
    movq    $134, %rdi
    movq    $SYS_exit, %rax
    syscall
.L_chk_fail_hang:
    jmp     .L_chk_fail_hang
    .size __stack_chk_fail, .-__stack_chk_fail


    /* --- _start ------------------------------------------------------
     * Linux process entry. The kernel hands us, on the stack (no
     * registers set):
     *
     *   (%rsp)        argc
     *   8(%rsp)       argv[0]
     *   ...           argv[argc-1]
     *   ...           NULL
     *   ...           envp[0] ...
     *
     * We read argc into %rdi and &argv[0] into %rsi so main(argc, argv)
     * gets standard parameters (main functions that ignore them are
     * fine). Then call main, and pass its int32 return in %eax to
     * SYS_exit as the process exit code.
     *
     * %rsp is 16-byte aligned at process entry per the x86_64 SysV ABI;
     * `call main` pushes the 8-byte return address, leaving %rsp 16-byte
     * aligned + 8 inside main's prologue, exactly as a normal call site —
     * so any SSE spill in generated code stays correctly aligned.
     *
     * HOSTED LANE: when this runtime is linked by clang against glibc (the
     * LLVM lane, scripts/adder_cc_llvm.sh), crt1.o already supplies `_start`
     * and calls main(argc, argv, envp) for us — and it is the only symbol in
     * this file that collides. Build with -DADDER_HOSTED to drop it and let
     * the C runtime do process start-up (which also runs glibc's initialisers,
     * required before any libc-dependent library can be called).
     */
#ifndef ADDER_HOSTED
    .globl _start
    .type _start, @function
_start:
    xorq    %rbp, %rbp                /* mark outermost frame */
    movq    (%rsp), %rdi             /* argc */
    leaq    8(%rsp), %rsi            /* &argv[0] */
    call    main
    movslq  %eax, %rdi               /* sign-extend int32 status -> rdi */
    movq    $SYS_exit, %rax
    syscall
.L_start_hang:                       /* SYS_exit never returns; spin defensively */
    jmp     .L_start_hang
    .size _start, .-_start
#endif /* !ADDER_HOSTED */


/* ====================================================================
 * POSIX file / fd surface.
 *
 * Under ADDER_HOSTED these are defined in user/linux-syscalls.c instead, for
 * two reasons that only showed up when the lane was actually run:
 *
 *  1. errno. These raw wrappers return -errno in %rax and never touch glibc's
 *     errno, so sys_errstr had nothing to report and every diagnostic in the
 *     tree printed "cannot open X: " with an empty reason.
 *  2. Directories. lib/p9.ad's p9_listdir reads a directory fd expecting a
 *     "NAME\n" stream (that is what the Hamnix DEV_DIR_FILE backing emits).
 *     Linux read(2) answers EISDIR, so `ls` links, runs, and fails. The C
 *     version synthesises the stream from readdir.
 *
 * The hosted definitions keep the -errno return convention exactly, so callers
 * that decode it are unaffected; they additionally set errno.
 * ==================================================================== */
#ifndef ADDER_HOSTED

    /* --- sys_read(fd, buf, count) -> int64 -------------------------- */
    .globl sys_read
    .type sys_read, @function
sys_read:
    movq    $SYS_read, %rax
    syscall
    ret
    .size sys_read, .-sys_read


    /* --- sys_write(fd, buf, count) -> int64 ------------------------- */
    .globl sys_write
    .type sys_write, @function
sys_write:
    movq    $SYS_write, %rax
    syscall
    ret
    .size sys_write, .-sys_write


    /* --- sys_open(path) -> int32 ------------------------------------
     * Mirrors user/runtime.S's SYS_OPEN *exactly*: ONE argument, opened
     * for READING. The host thunk loads the flags/mode itself (O_RDONLY,
     * mode 0) so the SAME source that reads a file on-device reads a real
     * host file under x86_64-linux -- the same contract sys_open_write
     * (below) already had, and the same one scripts/net9_host_shim.c's
     * C `sys_open(const char *path)` implements.
     *
     * This USED to take (path, flags, mode). That made `sys_open` the one
     * symbol in the tree with two different signatures depending on the
     * target, so a shared lib/ module (which declares the native 1-arg
     * form) linked into a *_host.ad harness (which declared the 3-arg
     * form) called it with garbage in %rsi/%rdx -- an open(2) with random
     * flags. Callers that need explicit Linux flags use sys_open3 below. */
    .globl sys_open
    .type sys_open, @function
sys_open:
    xorl    %esi, %esi              /* O_RDONLY */
    xorl    %edx, %edx              /* mode (unused without O_CREAT) */
    movq    $SYS_open, %rax
    syscall
    ret
    .size sys_open, .-sys_open


    /* --- sys_open3(path, flags, mode) -> int32 ----------------------
     * Raw Linux open(2) with caller-supplied flags: a0=path, a1=flags
     * (O_RDONLY=0, O_WRONLY=1, O_CREAT=0x40, O_TRUNC=0x200, ...),
     * a2=mode. HOST-ONLY (there is no on-device counterpart), so use it
     * only from code that never compiles for x86_64-adder-user. */
    .globl sys_open3
    .type sys_open3, @function
sys_open3:
    movq    $SYS_open, %rax
    syscall
    ret
    .size sys_open3, .-sys_open3


    /* --- sys_open_write(path) -> int32 ------------------------------
     * Mirrors user/runtime.S's SYS_OPEN_WRITE (open-or-create for write,
     * truncating an existing file). On the HOST this is a real Linux
     * open(2) with O_WRONLY|O_CREAT|O_TRUNC (0x241) and mode 0644 (0644
     * octal = 420). Only %rdi (path) is supplied by the caller; we load
     * the flags/mode ourselves so the SAME native source that writes a
     * file on-device also writes a real host file under x86_64-linux. */
    .globl sys_open_write
    .type sys_open_write, @function
sys_open_write:
    movq    $0x241, %rsi            /* O_WRONLY|O_CREAT|O_TRUNC */
    movq    $420, %rdx             /* mode 0644 */
    movq    $SYS_open, %rax
    syscall
    ret
    .size sys_open_write, .-sys_open_write


    /* --- sys_close(fd) -> int32 ------------------------------------- */
    .globl sys_close
    .type sys_close, @function
sys_close:
    movq    $SYS_close, %rax
    syscall
    ret
    .size sys_close, .-sys_close


    /* --- sys_lseek(fd, offset, whence) -> int64 --------------------- */
    .globl sys_lseek
    .type sys_lseek, @function
sys_lseek:
    movq    $SYS_lseek, %rax
    syscall
    ret
    .size sys_lseek, .-sys_lseek


    /* --- sys_mkdir(path) -> int32 -----------------------------------
     * The native primitive takes ONLY a path (mode is fixed on-device).
     * On the HOST we supply mode 0755 (=493) ourselves so the SAME native
     * source that mkdir()s on-device also creates a real host directory.
     * Returns 0 or -errno. */
    .globl sys_mkdir
    .type sys_mkdir, @function
sys_mkdir:
    movq    $493, %rsi              /* mode 0755 */
    movq    $SYS_mkdir, %rax
    syscall
    ret
    .size sys_mkdir, .-sys_mkdir


    /* --- sys_unlink(path) -> int32 ---------------------------------- */
    .globl sys_unlink
    .type sys_unlink, @function
sys_unlink:
    movq    $SYS_unlink, %rax
    syscall
    ret
    .size sys_unlink, .-sys_unlink


    /* --- sys_dup2(oldfd, newfd) -> int32 ---------------------------- */
    .globl sys_dup2
    .type sys_dup2, @function
sys_dup2:
    movq    $SYS_dup2, %rax
    syscall
    ret
    .size sys_dup2, .-sys_dup2
#endif /* !ADDER_HOSTED — POSIX file/fd surface */


    /* --- Plan 9 / process-spawn primitives with NO host equivalent ---
     *
     * CORRECTION (measured, not assumed): this comment's claim that these
     * "have NO host equivalent" is only true of some of them. sys_rfork,
     * sys_execve_env and sys_resolve are fork(2), execve(2) and getaddrinfo(3)
     * — they were stubbed here because the harnesses that first used this
     * runtime never spawned a process, not because Linux cannot express them.
     * HANDOFF.md §4.1 listed all three under "genuinely implemented", which
     * was wrong; they are `return -1` below. Under ADDER_HOSTED the ones that
     * do have an equivalent are implemented in user/linux-syscalls.c.
     *
     * lib/p9.ad (transitively imported by lib/hamfmcore.ad) references these
     * syscalls. A host binary that only exercises the browse core's FILE ops
     * (mkdir/touch/unlink/rename via the wrappers above) never CALLS them, but
     * they must RESOLVE for the link to succeed. In the freestanding lane they
     * stay fail-closed (return -1); if a host path ever reaches one it errors
     * cleanly rather than corrupting state.
     * ---------------------------------------------------------------- */
#ifndef ADDER_HOSTED
    .globl sys_rfork
    .type sys_rfork, @function
sys_rfork:
    movq    $-1, %rax
    ret
    .size sys_rfork, .-sys_rfork

    .globl sys_execve_env
    .type sys_execve_env, @function
sys_execve_env:
    movq    $-1, %rax
    ret
    .size sys_execve_env, .-sys_execve_env

    .globl sys_fdbind
    .type sys_fdbind, @function
sys_fdbind:
    movq    $-1, %rax
    ret
    .size sys_fdbind, .-sys_fdbind

    .globl sys_chan_dir_mode
    .type sys_chan_dir_mode, @function
sys_chan_dir_mode:
    movq    $-1, %rax
    ret
    .size sys_chan_dir_mode, .-sys_chan_dir_mode

    .globl sys_listdir_records
    .type sys_listdir_records, @function
sys_listdir_records:
    movq    $-1, %rax
    ret
    .size sys_listdir_records, .-sys_listdir_records

    .globl sys_stat_p9
    .type sys_stat_p9, @function
sys_stat_p9:
    movq    $-1, %rax
    ret
    .size sys_stat_p9, .-sys_stat_p9

    /* --- sys_resolve(hostname, hlen) -> int64 ----------------------
       Native-ABI in-kernel DNS resolve (Hamnix syscall 269). The host
       Linux kernel has no such resolver, so this is a host stub that
       reports failure — it exists only so http9.ad (which imports it)
       links for the x86_64-linux host unit tests. On-device the real
       wrapper lives in the native user runtime, not here. */
    .globl sys_resolve
    .type sys_resolve, @function
sys_resolve:
    movq    $-1, %rax
    ret
    .size sys_resolve, .-sys_resolve
#endif /* !ADDER_HOSTED — Plan 9 / spawn primitives */


    /* --- sys_exit(code) — never returns ----------------------------- */
    .globl sys_exit
    .type sys_exit, @function
sys_exit:
    movq    $SYS_exit, %rax
    syscall
.L_exit_hang:
    jmp     .L_exit_hang
    .size sys_exit, .-sys_exit

    /* ================================================================
     * hamsh host-language runtime (scripts/test_hamsh_lang_host.sh)
     *
     * user/hamsh.ad — the SAME shell that runs as /init on-device —
     * compiled for x86_64-linux so its Python-flavored LANGUAGE core
     * (lexer, parser, tree-walking evaluator: arithmetic, strings,
     * if/for/while, def/call, variable expansion) can be unit-tested on
     * the developer's host with NO QEMU. hamsh binds ~30 kernel /
     * namespace / 9P syscalls that do not exist on Linux. Two honest
     * classes:
     *
     *   (1) Ops with a faithful host equivalent — mapped to the real
     *       Linux syscall so the shared native source behaves the same on
     *       host (cwd, chdir, dup, mmap arena, getuid, yield, setpgid,
     *       and a genuine non-blocking read for the line editor).
     *   (2) Plan 9 namespace / chan / spawn / service ops with NO host
     *       analog — fail-closed stubs (return -1, or 0/empty where the
     *       type demands it). This mirrors the fail-closed spawn stubs
     *       above (sys_rfork / sys_execve_env / ...). A host language
     *       test never reaches these; if a namespace / pipeline path ever
     *       did, it errors cleanly rather than faking success.
     *
     * The test drives the shell over a stdin PIPE with `--no-echo`, so
     * two stubs are shaped to make the interactive editor consume piped
     * input honestly: sys_fdslot_kind reports fd 0 as a pipe read-end
     * (DEVFD_PIPE_R = 2) so ed_readline skips its console getty-flush that
     * would otherwise discard the buffered script, and sys_read_nb is a
     * true non-blocking read that maps -EAGAIN to 0 (the on-device
     * "no byte ready yet" contract, distinct from a negative true EOF).
     * ================================================================ */

    /* --- (1) real host syscalls ------------------------------------- */

#ifndef ADDER_HOSTED   /* hosted: user/linux-syscalls.c — see the note above */
    /* sys_getcwd(buf, count) -> int64  (rdi=buf, rsi=count already aligned) */
    .globl sys_getcwd
    .type sys_getcwd, @function
sys_getcwd:
    movq    $SYS_getcwd, %rax
    syscall
    ret
    .size sys_getcwd, .-sys_getcwd

    /* sys_chdir(path) -> int32 */
    .globl sys_chdir
    .type sys_chdir, @function
sys_chdir:
    movq    $SYS_chdir, %rax
    syscall
    ret
    .size sys_chdir, .-sys_chdir

    /* sys_dup(oldfd) -> int32 */
    .globl sys_dup
    .type sys_dup, @function
sys_dup:
    movq    $SYS_dup, %rax
    syscall
    ret
    .size sys_dup, .-sys_dup
#endif /* !ADDER_HOSTED */

    /* sys_getuid() -> uint32 */
    .globl sys_getuid
    .type sys_getuid, @function
sys_getuid:
    movq    $SYS_getuid, %rax
    syscall
    ret
    .size sys_getuid, .-sys_getuid

    /* sys_yield() -> int32  (sched_yield) */
    .globl sys_yield
    .type sys_yield, @function
sys_yield:
    movq    $SYS_sched_yield, %rax
    syscall
    ret
    .size sys_yield, .-sys_yield

    /* sys_setpgid(pid, pgid) -> int32  (rdi=pid, rsi=pgid) */
    .globl sys_setpgid
    .type sys_setpgid, @function
sys_setpgid:
    movq    $SYS_setpgid, %rax
    syscall
    ret
    .size sys_setpgid, .-sys_setpgid

    /* sys_mmap(addr, len, prot, flags, fd, off) -> int64
     * Fn convention rdi,rsi,rdx,rcx,r8,r9 -> syscall wants arg4 in r10.
     * Backs hamUI's module arena (_h_v2_alloc) so any host allocation
     * path works rather than fail-closed. */
    .globl sys_mmap
    .type sys_mmap, @function
sys_mmap:
    movq    %rcx, %r10
    movq    $SYS_mmap, %rax
    syscall
    ret
    .size sys_mmap, .-sys_mmap

    /* sys_munmap(addr, length) -> int32 : real host munmap. */
    .globl sys_munmap
    .type sys_munmap, @function
sys_munmap:
    movq    $SYS_munmap, %rax
    syscall
    ret
    .size sys_munmap, .-sys_munmap

    /* sys_read_nb(fd, buf, count) -> int64 : genuine non-blocking read.
     * Mark the fd O_NONBLOCK (F_SETFL=4, O_NONBLOCK=0x800) then read. Map
     * -EAGAIN (-11) to 0 so the on-device contract holds: 0 == "no byte
     * ready yet" (editor idles + yields), a negative == true EOF/error.
     * This is what lets the hamsh line editor consume a piped host script
     * over fd 0 (scripts/test_hamsh_lang_host.sh). F_SETFL cannot alter
     * the access mode, so a read fd stays readable.
     *
     * Under ADDER_HOSTED this is in user/linux-syscalls.c instead, because a
     * raw read here would bypass the synthetic-device table -- and hamui
     * polls /dev/wsys/<wid>/{keys,pointer} with EXACTLY this call, so a raw
     * read would return 0 for ever and no GUI app would see input. */
#ifndef ADDER_HOSTED
    .globl sys_read_nb
    .type sys_read_nb, @function
sys_read_nb:
    pushq   %rdi
    pushq   %rsi
    pushq   %rdx
    movq    $4, %rsi               /* F_SETFL */
    movq    $0x800, %rdx           /* O_NONBLOCK */
    movq    $SYS_fcntl, %rax
    syscall
    popq    %rdx
    popq    %rsi
    popq    %rdi
    movq    $SYS_read, %rax
    syscall
    cmpq    $-11, %rax             /* -EAGAIN -> report 0 (no data yet) */
    jne     .L_read_nb_done
    xorq    %rax, %rax
.L_read_nb_done:
    ret
    .size sys_read_nb, .-sys_read_nb
#endif /* !ADDER_HOSTED */

    /* --- (2) Plan 9 / namespace / chan / spawn — fail-closed stubs --- */

    /* sys_fdslot_kind(pid, fdnum) -> int32 : the shell probes fd 0's kind
     * to decide whether to run its console getty-flush. Report fd 0 as a
     * pipe read-end (DEVFD_PIPE_R = 2) so the flush is skipped and piped
     * script bytes survive; every other fd has no host slot (-1). */
    .globl sys_fdslot_kind
    .type sys_fdslot_kind, @function
sys_fdslot_kind:
    testq   %rsi, %rsi             /* fdnum == 0 ? */
    jnz     .L_fdslot_notzero
    movq    $2, %rax               /* DEVFD_PIPE_R */
    ret
.L_fdslot_notzero:
    movq    $-1, %rax
    ret
    .size sys_fdslot_kind, .-sys_fdslot_kind

    /* sys_errstr(buf, nbuf) -> int32 : no Plan 9 error string on host.
     * NUL-terminate the caller buffer (if any) and report empty.
     * Under ADDER_HOSTED user/linux-syscalls.c backs this with strerror_r on
     * errno, which is why error messages carry a reason in the glibc lane. */
#ifndef ADDER_HOSTED
    .globl sys_errstr
    .type sys_errstr, @function
sys_errstr:
    testq   %rsi, %rsi
    jz      .L_errstr_done
    movb    $0, (%rdi)
.L_errstr_done:
    xorq    %rax, %rax
    ret
    .size sys_errstr, .-sys_errstr
#endif /* !ADDER_HOSTED */

    /* sys_nsid() -> uint64 : no namespace id on host. */
    .globl sys_nsid
    .type sys_nsid, @function
sys_nsid:
    xorq    %rax, %rax
    ret
    .size sys_nsid, .-sys_nsid

    /* sys_get_jiffies() -> uint64 : no kernel tick; report 0.
     * Hosted: user/linux-syscalls.c derives a real 100 Hz tick from
     * CLOCK_MONOTONIC. Reporting a frozen 0 here is why every jiffies
     * deadline loop in the tree (sleep, watch, memhog, nice_*) spins
     * forever. */
#ifndef ADDER_HOSTED
    .globl sys_get_jiffies
    .type sys_get_jiffies, @function
sys_get_jiffies:
    xorq    %rax, %rax
    ret
    .size sys_get_jiffies, .-sys_get_jiffies
#endif /* !ADDER_HOSTED */

    /* The remaining ops share one fail-closed body: return -1.
     *
     * Under ADDER_HOSTED (the glibc LLVM lane) the ones that DO have a real
     * Linux answer are defined instead by user/linux-syscalls.c, which can
     * reach wait4/tcsetpgrp/kill/setuid and errno. They are guarded out here
     * so the two runtimes do not both define them. What is left in every lane
     * is the genuinely Plan 9-only surface: mount/unmount/nslabel, the #s srv
     * and #svc service registries, and the fdslot/openchan channel ops. Those
     * have no POSIX equivalent and stay fail-closed until §3/§4 of HANDOFF.md
     * is decided. */
#ifndef ADDER_HOSTED
    .globl sys_bind
    .type sys_bind, @function
sys_bind:
    .globl sys_setuid
    .type sys_setuid, @function
sys_setuid:
    .globl sys_pgrp_kill
    .type sys_pgrp_kill, @function
sys_pgrp_kill:
    .globl sys_tcsetpgrp
    .type sys_tcsetpgrp, @function
sys_tcsetpgrp:
    .globl sys_waitpid
    .type sys_waitpid, @function
sys_waitpid:
    .globl sys_waitpid_jc
    .type sys_waitpid_jc, @function
sys_waitpid_jc:
    .globl sys_waitpid_nb_raw
    .type sys_waitpid_nb_raw, @function
sys_waitpid_nb_raw:
    .globl sys_waitfds
    .type sys_waitfds, @function
sys_waitfds:
    .globl sys_pipechan
    .type sys_pipechan, @function
sys_pipechan:
    .globl sys_unmount
    .type sys_unmount, @function
sys_unmount:
#endif /* !ADDER_HOSTED */
    .globl sys_mount
    .type sys_mount, @function
sys_mount:
    .globl sys_nslabel
    .type sys_nslabel, @function
sys_nslabel:
    .globl sys_srv_open
    .type sys_srv_open, @function
sys_srv_open:
    .globl sys_openchan
    .type sys_openchan, @function
sys_openchan:
    .globl sys_fdslot_arg
    .type sys_fdslot_arg, @function
sys_fdslot_arg:
    .globl sys_svc_publish
    .type sys_svc_publish, @function
sys_svc_publish:
    .globl sys_svc_ctl
    .type sys_svc_ctl, @function
sys_svc_ctl:
    .globl sys_setuid_auth
    .type sys_setuid_auth, @function
sys_setuid_auth:
    movq    $-1, %rax
    ret

    /* Non-executable stack marker (suppress ld's executable-stack warn). */
    .section .note.GNU-stack, "", @progbits
