; syscalls64.asm - 64-bit Linux syscall interface for Brainhair
; Uses the System V AMD64 ABI

[BITS 64]

section .text

; Exit syscall - syscall number 60
global sys_exit
sys_exit:
    mov rax, 60         ; sys_exit
    ; rdi already has exit code
    syscall
    ret

; Write syscall - syscall number 1
global sys_write
sys_write:
    mov rax, 1          ; sys_write
    ; rdi = fd, rsi = buf, rdx = count (already in place)
    syscall
    ret

; Read syscall - syscall number 0
global sys_read
sys_read:
    mov rax, 0          ; sys_read
    ; rdi = fd, rsi = buf, rdx = count (already in place)
    syscall
    ret

; Open syscall - syscall number 2
global sys_open
sys_open:
    mov rax, 2          ; sys_open
    ; rdi = pathname, rsi = flags, rdx = mode (already in place)
    syscall
    ret

; Close syscall - syscall number 3
global sys_close
sys_close:
    mov rax, 3          ; sys_close
    ; rdi = fd (already in place)
    syscall
    ret

; lseek syscall - syscall number 8
global sys_lseek
sys_lseek:
    mov rax, 8          ; sys_lseek
    ; rdi = fd, rsi = offset, rdx = whence (already in place)
    syscall
    ret

; brk syscall - syscall number 12
global sys_brk
sys_brk:
    mov rax, 12         ; sys_brk
    ; rdi = addr (already in place)
    syscall
    ret

; mmap syscall - syscall number 9
global sys_mmap
sys_mmap:
    mov rax, 9          ; sys_mmap
    mov r10, rcx        ; Linux uses r10 for 4th arg in syscalls
    ; rdi = addr, rsi = length, rdx = prot, r10 = flags, r8 = fd, r9 = offset
    syscall
    ret

; munmap syscall - syscall number 11
global sys_munmap
sys_munmap:
    mov rax, 11         ; sys_munmap
    ; rdi = addr, rsi = length (already in place)
    syscall
    ret

; fork syscall - syscall number 57
global sys_fork
sys_fork:
    mov rax, 57         ; sys_fork
    syscall
    ret

; execve syscall - syscall number 59
global sys_execve
sys_execve:
    mov rax, 59         ; sys_execve
    ; rdi = filename, rsi = argv, rdx = envp (already in place)
    syscall
    ret

; wait4 syscall - syscall number 61
global sys_wait4
sys_wait4:
    mov rax, 61         ; sys_wait4
    mov r10, rcx        ; rusage in r10
    ; rdi = pid, rsi = status, rdx = options, r10 = rusage
    syscall
    ret

; getpid syscall - syscall number 39
global sys_getpid
sys_getpid:
    mov rax, 39         ; sys_getpid
    syscall
    ret

; getppid syscall - syscall number 110
global sys_getppid
sys_getppid:
    mov rax, 110        ; sys_getppid
    syscall
    ret

; getuid syscall - syscall number 102
global sys_getuid
sys_getuid:
    mov rax, 102        ; sys_getuid
    syscall
    ret

; getgid syscall - syscall number 104
global sys_getgid
sys_getgid:
    mov rax, 104        ; sys_getgid
    syscall
    ret

; kill syscall - syscall number 62
global sys_kill
sys_kill:
    mov rax, 62         ; sys_kill
    ; rdi = pid, rsi = sig (already in place)
    syscall
    ret

; nanosleep syscall - syscall number 35
global sys_nanosleep
sys_nanosleep:
    mov rax, 35         ; sys_nanosleep
    ; rdi = req, rsi = rem (already in place)
    syscall
    ret

; stat syscall - syscall number 4
global sys_stat
sys_stat:
    mov rax, 4          ; sys_stat
    ; rdi = pathname, rsi = statbuf (already in place)
    syscall
    ret

; fstat syscall - syscall number 5
global sys_fstat
sys_fstat:
    mov rax, 5          ; sys_fstat
    ; rdi = fd, rsi = statbuf (already in place)
    syscall
    ret

; getcwd syscall - syscall number 79
global sys_getcwd
sys_getcwd:
    mov rax, 79         ; sys_getcwd
    ; rdi = buf, rsi = size (already in place)
    syscall
    ret

; chdir syscall - syscall number 80
global sys_chdir
sys_chdir:
    mov rax, 80         ; sys_chdir
    ; rdi = path (already in place)
    syscall
    ret

; mkdir syscall - syscall number 83
global sys_mkdir
sys_mkdir:
    mov rax, 83         ; sys_mkdir
    ; rdi = pathname, rsi = mode (already in place)
    syscall
    ret

; rmdir syscall - syscall number 84
global sys_rmdir
sys_rmdir:
    mov rax, 84         ; sys_rmdir
    ; rdi = pathname (already in place)
    syscall
    ret

; unlink syscall - syscall number 87
global sys_unlink
sys_unlink:
    mov rax, 87         ; sys_unlink
    ; rdi = pathname (already in place)
    syscall
    ret

; rename syscall - syscall number 82
global sys_rename
sys_rename:
    mov rax, 82         ; sys_rename
    ; rdi = oldpath, rsi = newpath (already in place)
    syscall
    ret

; dup syscall - syscall number 32
global sys_dup
sys_dup:
    mov rax, 32         ; sys_dup
    ; rdi = oldfd (already in place)
    syscall
    ret

; dup2 syscall - syscall number 33
global sys_dup2
sys_dup2:
    mov rax, 33         ; sys_dup2
    ; rdi = oldfd, rsi = newfd (already in place)
    syscall
    ret

; pipe syscall - syscall number 22
global sys_pipe
sys_pipe:
    mov rax, 22         ; sys_pipe
    ; rdi = pipefd (already in place)
    syscall
    ret

; ioctl syscall - syscall number 16
global sys_ioctl
sys_ioctl:
    mov rax, 16         ; sys_ioctl
    ; rdi = fd, rsi = request, rdx = arg (already in place)
    syscall
    ret

; getdents64 syscall - syscall number 217
global sys_getdents64
sys_getdents64:
    mov rax, 217        ; sys_getdents64
    ; rdi = fd, rsi = dirp, rdx = count (already in place)
    syscall
    ret

; clock_gettime syscall - syscall number 228
global sys_clock_gettime
sys_clock_gettime:
    mov rax, 228        ; sys_clock_gettime
    ; rdi = clk_id, rsi = tp (already in place)
    syscall
    ret

; socket syscall - syscall number 41
global sys_socket
sys_socket:
    mov rax, 41         ; sys_socket
    ; rdi = domain, rsi = type, rdx = protocol (already in place)
    syscall
    ret

; connect syscall - syscall number 42
global sys_connect
sys_connect:
    mov rax, 42         ; sys_connect
    ; rdi = sockfd, rsi = addr, rdx = addrlen (already in place)
    syscall
    ret

; bind syscall - syscall number 49
global sys_bind
sys_bind:
    mov rax, 49         ; sys_bind
    ; rdi = sockfd, rsi = addr, rdx = addrlen (already in place)
    syscall
    ret

; listen syscall - syscall number 50
global sys_listen
sys_listen:
    mov rax, 50         ; sys_listen
    ; rdi = sockfd, rsi = backlog (already in place)
    syscall
    ret

; accept syscall - syscall number 43
global sys_accept
sys_accept:
    mov rax, 43         ; sys_accept
    ; rdi = sockfd, rsi = addr, rdx = addrlen (already in place)
    syscall
    ret

; sendto syscall - syscall number 44
global sys_sendto
sys_sendto:
    mov rax, 44         ; sys_sendto
    mov r10, rcx        ; flags in r10
    ; rdi = sockfd, rsi = buf, rdx = len, r10 = flags, r8 = dest_addr, r9 = addrlen
    syscall
    ret

; recvfrom syscall - syscall number 45
global sys_recvfrom
sys_recvfrom:
    mov rax, 45         ; sys_recvfrom
    mov r10, rcx        ; flags in r10
    ; rdi = sockfd, rsi = buf, rdx = len, r10 = flags, r8 = src_addr, r9 = addrlen
    syscall
    ret

; _start entry point
global _start
_start:
    ; Get argc and argv from stack
    pop rdi             ; argc in rdi (first arg)
    mov rsi, rsp        ; argv in rsi (second arg)

    ; Call main
    extern main
    call main

    ; Exit with return value from main
    mov rdi, rax
    mov rax, 60         ; sys_exit
    syscall

section .data

section .bss
