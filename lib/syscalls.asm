; PoodillionOS Syscall Library - Assembly Implementation
; Linux x86 32-bit syscalls via int 0x80

bits 32

global syscall1
global syscall2
global syscall3
global syscall4
global syscall5
global syscall6
global fast_memcpy

; Kernel syscalls (int 0x42) for networking
global net_syscall0
global net_syscall1
global net_syscall2
global net_syscall3

section .text

; syscall1(num, arg1)
syscall1:
    push ebp
    mov ebp, esp
    push ebx

    mov eax, [ebp+8]   ; syscall number
    mov ebx, [ebp+12]  ; arg1

    int 0x80           ; Linux syscall

    pop ebx
    pop ebp
    ret

; syscall2(num, arg1, arg2)
syscall2:
    push ebp
    mov ebp, esp
    push ebx
    push ecx

    mov eax, [ebp+8]   ; syscall number
    mov ebx, [ebp+12]  ; arg1
    mov ecx, [ebp+16]  ; arg2

    int 0x80           ; Linux syscall

    pop ecx
    pop ebx
    pop ebp
    ret

; syscall3(num, arg1, arg2, arg3)
syscall3:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push edx

    mov eax, [ebp+8]   ; syscall number
    mov ebx, [ebp+12]  ; arg1
    mov ecx, [ebp+16]  ; arg2
    mov edx, [ebp+20]  ; arg3

    int 0x80           ; Linux syscall

    pop edx
    pop ecx
    pop ebx
    pop ebp
    ret

; syscall4(num, arg1, arg2, arg3, arg4)
syscall4:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push edx
    push esi

    mov eax, [ebp+8]   ; syscall number
    mov ebx, [ebp+12]  ; arg1
    mov ecx, [ebp+16]  ; arg2
    mov edx, [ebp+20]  ; arg3
    mov esi, [ebp+24]  ; arg4

    int 0x80           ; Linux syscall

    pop esi
    pop edx
    pop ecx
    pop ebx
    pop ebp
    ret

; syscall5(num, arg1, arg2, arg3, arg4, arg5)
syscall5:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov eax, [ebp+8]   ; syscall number
    mov ebx, [ebp+12]  ; arg1
    mov ecx, [ebp+16]  ; arg2
    mov edx, [ebp+20]  ; arg3
    mov esi, [ebp+24]  ; arg4
    mov edi, [ebp+28]  ; arg5

    int 0x80           ; Linux syscall

    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop ebp
    ret

; syscall6(num, arg1, arg2, arg3, arg4, arg5, arg6)
; Used for mmap and other complex syscalls
syscall6:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp           ; arg6 goes in ebp

    mov eax, [ebp+8]   ; syscall number
    mov ebx, [ebp+12]  ; arg1
    mov ecx, [ebp+16]  ; arg2
    mov edx, [ebp+20]  ; arg3
    mov esi, [ebp+24]  ; arg4
    mov edi, [ebp+28]  ; arg5
    mov ebp, [ebp+32]  ; arg6

    int 0x80           ; Linux syscall

    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop ebp
    ret

; fast_memcpy(dst, src, count_bytes)
; Uses rep movsd for fast 32-bit aligned copies
fast_memcpy:
    push ebp
    mov ebp, esp
    push edi
    push esi
    push ecx

    mov edi, [ebp+8]   ; dst
    mov esi, [ebp+12]  ; src
    mov ecx, [ebp+16]  ; count in bytes
    shr ecx, 2         ; convert to dwords (divide by 4)

    cld                ; clear direction flag (forward copy)
    rep movsd          ; copy ecx dwords from [esi] to [edi]

    pop ecx
    pop esi
    pop edi
    pop ebp
    ret

; ============= Kernel syscalls (int 0x42) for networking =============

; net_syscall0(num) - no arguments
net_syscall0:
    push ebp
    mov ebp, esp
    push ebx

    mov eax, [ebp+8]   ; syscall number

    int 0x42           ; kernel syscall

    pop ebx
    pop ebp
    ret

; net_syscall1(num, arg1)
net_syscall1:
    push ebp
    mov ebp, esp
    push ebx

    mov eax, [ebp+8]   ; syscall number
    mov ebx, [ebp+12]  ; arg1

    int 0x42           ; kernel syscall

    pop ebx
    pop ebp
    ret

; net_syscall2(num, arg1, arg2)
net_syscall2:
    push ebp
    mov ebp, esp
    push ebx
    push ecx

    mov eax, [ebp+8]   ; syscall number
    mov ebx, [ebp+12]  ; arg1
    mov ecx, [ebp+16]  ; arg2

    int 0x42           ; kernel syscall

    pop ecx
    pop ebx
    pop ebp
    ret

; net_syscall3(num, arg1, arg2, arg3)
net_syscall3:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push edx

    mov eax, [ebp+8]   ; syscall number
    mov ebx, [ebp+12]  ; arg1
    mov ecx, [ebp+16]  ; arg2
    mov edx, [ebp+20]  ; arg3

    int 0x42           ; kernel syscall

    pop edx
    pop ecx
    pop ebx
    pop ebp
    ret
