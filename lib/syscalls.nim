# PoodillionOS Syscall Library
# Linux syscall numbers and wrappers for Mini-Nim utilities

# Linux syscall numbers (x86 32-bit)
const SYS_exit: int32 = 1
const SYS_fork: int32 = 2
const SYS_read: int32 = 3
const SYS_write: int32 = 4
const SYS_open: int32 = 5
const SYS_close: int32 = 6
const SYS_waitpid: int32 = 7
const SYS_creat: int32 = 8
const SYS_link: int32 = 9
const SYS_unlink: int32 = 10
const SYS_execve: int32 = 11
const SYS_chdir: int32 = 12
const SYS_time: int32 = 13
const SYS_mknod: int32 = 14
const SYS_chmod: int32 = 15
const SYS_lchown: int32 = 16
const SYS_stat: int32 = 18
const SYS_lseek: int32 = 19
const SYS_getpid: int32 = 20
const SYS_mount: int32 = 21
const SYS_umount: int32 = 22
const SYS_setuid: int32 = 23
const SYS_getuid: int32 = 24
const SYS_stime: int32 = 25
const SYS_ptrace: int32 = 26
const SYS_alarm: int32 = 27
const SYS_fstat: int32 = 28
const SYS_pause: int32 = 29
const SYS_utime: int32 = 30
const SYS_access: int32 = 33
const SYS_sync: int32 = 36
const SYS_kill: int32 = 37
const SYS_rename: int32 = 38
const SYS_mkdir: int32 = 39
const SYS_rmdir: int32 = 40
const SYS_dup: int32 = 41
const SYS_pipe: int32 = 42
const SYS_times: int32 = 43
const SYS_brk: int32 = 45
const SYS_setgid: int32 = 46
const SYS_getgid: int32 = 47
const SYS_signal: int32 = 48
const SYS_geteuid: int32 = 49
const SYS_getegid: int32 = 50
const SYS_ioctl: int32 = 54
const SYS_fcntl: int32 = 55
const SYS_setpgid: int32 = 57
const SYS_umask: int32 = 60
const SYS_chroot: int32 = 61
const SYS_ustat: int32 = 62
const SYS_dup2: int32 = 63
const SYS_getppid: int32 = 64
const SYS_getpgrp: int32 = 65
const SYS_setsid: int32 = 66
const SYS_sigaction: int32 = 67
const SYS_setreuid: int32 = 70
const SYS_setregid: int32 = 71
const SYS_sigsuspend: int32 = 72
const SYS_sigpending: int32 = 73
const SYS_sethostname: int32 = 74
const SYS_setrlimit: int32 = 75
const SYS_getrlimit: int32 = 76
const SYS_getrusage: int32 = 77
const SYS_gettimeofday: int32 = 78
const SYS_settimeofday: int32 = 79
const SYS_getgroups: int32 = 80
const SYS_setgroups: int32 = 81
const SYS_symlink: int32 = 83
const SYS_readlink: int32 = 85
const SYS_uselib: int32 = 86
const SYS_swapon: int32 = 87
const SYS_reboot: int32 = 88
const SYS_readdir: int32 = 89
const SYS_mmap: int32 = 90
const SYS_munmap: int32 = 91
const SYS_truncate: int32 = 92
const SYS_ftruncate: int32 = 93
const SYS_fchmod: int32 = 94
const SYS_fchown: int32 = 95
const SYS_getpriority: int32 = 96
const SYS_setpriority: int32 = 97
const SYS_statfs: int32 = 99
const SYS_fstatfs: int32 = 100
const SYS_socketcall: int32 = 102
const SYS_syslog: int32 = 103
const SYS_setitimer: int32 = 104
const SYS_getitimer: int32 = 105
const SYS_newstat: int32 = 106
const SYS_newlstat: int32 = 107
const SYS_newfstat: int32 = 108
const SYS_uname: int32 = 122

# File descriptors
const STDIN: int32 = 0
const STDOUT: int32 = 1
const STDERR: int32 = 2

# File open flags
const O_RDONLY: int32 = 0
const O_WRONLY: int32 = 1
const O_RDWR: int32 = 2
const O_CREAT: int32 = 64
const O_TRUNC: int32 = 512
const O_APPEND: int32 = 1024

# File permissions
const S_IRWXU: int32 = 448   # 0700 - user rwx
const S_IRUSR: int32 = 256   # 0400 - user r
const S_IWUSR: int32 = 128   # 0200 - user w
const S_IXUSR: int32 = 64    # 0100 - user x
const S_IRWXG: int32 = 56    # 0070 - group rwx
const S_IRGRP: int32 = 32    # 0040 - group r
const S_IWGRP: int32 = 16    # 0020 - group w
const S_IXGRP: int32 = 8     # 0010 - group x
const S_IRWXO: int32 = 7     # 0007 - others rwx
const S_IROTH: int32 = 4     # 0004 - others r
const S_IWOTH: int32 = 2     # 0002 - others w
const S_IXOTH: int32 = 1     # 0001 - others x

# Exit codes
const EXIT_SUCCESS: int32 = 0
const EXIT_FAILURE: int32 = 1

# Syscall wrappers (implemented in assembly)
extern proc syscall1(num: int32, arg1: int32): int32
extern proc syscall2(num: int32, arg1: int32, arg2: int32): int32
extern proc syscall3(num: int32, arg1: int32, arg2: int32, arg3: int32): int32
extern proc syscall4(num: int32, arg1: int32, arg2: int32, arg3: int32, arg4: int32): int32

# High-level wrappers
proc exit(code: int32) =
  discard syscall1(SYS_exit, code)

proc read(fd: int32, buf: ptr uint8, count: int32): int32 =
  return syscall3(SYS_read, fd, cast[int32](buf), count)

proc write(fd: int32, buf: ptr uint8, count: int32): int32 =
  return syscall3(SYS_write, fd, cast[int32](buf), count)

proc open(path: ptr uint8, flags: int32, mode: int32): int32 =
  return syscall3(SYS_open, cast[int32](path), flags, mode)

proc close(fd: int32): int32 =
  return syscall1(SYS_close, fd)

proc getpid(): int32 =
  return syscall1(SYS_getpid, 0)

proc getuid(): int32 =
  return syscall1(SYS_getuid, 0)

# String utilities (helper functions)
proc strlen(s: ptr uint8): int32 =
  var len: int32 = 0
  while s[len] != cast[uint8](0):
    len = len + 1
  return len

proc strcmp(s1: ptr uint8, s2: ptr uint8): int32 =
  var i: int32 = 0
  while true:
    var c1: uint8 = s1[i]
    var c2: uint8 = s2[i]
    if c1 != c2:
      if c1 < c2:
        return -1
      return 1
    if c1 == cast[uint8](0):
      return 0
    i = i + 1
  return 0

proc strcpy(dest: ptr uint8, src: ptr uint8) =
  var i: int32 = 0
  while src[i] != cast[uint8](0):
    dest[i] = src[i]
    i = i + 1
  dest[i] = cast[uint8](0)

# Print utilities
proc print(msg: ptr uint8) =
  var len: int32 = strlen(msg)
  discard write(STDOUT, msg, len)

proc println(msg: ptr uint8) =
  print(msg)
  discard write(STDOUT, cast[ptr uint8]("\n"), 1)

proc perror(msg: ptr uint8) =
  var len: int32 = strlen(msg)
  discard write(STDERR, msg, len)
  discard write(STDERR, cast[ptr uint8]("\n"), 1)
