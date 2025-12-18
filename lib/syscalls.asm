; PoodillionOS Syscall Library - Assembly Implementation
; Linux x86 32-bit syscalls via int 0x80

bits 32

global syscall1
global syscall2
global syscall3
global syscall4
global syscall5
global syscall6

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
