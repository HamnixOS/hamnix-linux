; PoodillionOS Syscall Library - Assembly Implementation
; Linux x86 32-bit syscalls via int 0x80

bits 32

global syscall1
global syscall2
global syscall3
global syscall4

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
