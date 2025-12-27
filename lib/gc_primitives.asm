; gc_primitives.asm - Low-level GC assembly primitives
; Provides stack inspection and atomic operations for garbage collector

section .data
    stack_bottom: dd 0

section .text

; Export symbols
global gc_get_stack_pointer
global gc_get_stack_bottom
global gc_set_stack_bottom
global gc_scan_stack
global gc_memory_barrier
global gc_atomic_set
global gc_atomic_get
global gc_atomic_cas

; proc gc_get_stack_pointer(): int32
; Returns the current stack pointer value
gc_get_stack_pointer:
    push ebp
    mov ebp, esp
    mov eax, esp
    add eax, 8          ; Adjust for our push ebp and return addr
    pop ebp
    ret

; proc gc_get_stack_bottom(): int32
; Returns the recorded stack bottom
gc_get_stack_bottom:
    push ebp
    mov ebp, esp
    mov eax, [stack_bottom]
    pop ebp
    ret

; proc gc_set_stack_bottom(address: int32)
; Sets the stack bottom address for scanning
gc_set_stack_bottom:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]
    mov [stack_bottom], eax
    pop ebp
    ret

; proc gc_scan_stack(callback: int32, context: int32): int32
; Scans the stack for potential pointers and calls callback for each
; callback signature: callback(value: int32, context: int32)
; Returns number of values scanned
gc_scan_stack:
    push ebp
    mov ebp, esp
    push ebx
    push esi
    push edi

    mov edi, [ebp+8]    ; callback function
    mov esi, [ebp+12]   ; context

    mov eax, esp        ; Start from current ESP
    mov ebx, [stack_bottom]

    xor ecx, ecx        ; Count

.scan_loop:
    cmp eax, ebx
    jae .done

    ; Push callback args
    push esi            ; context
    push dword [eax]    ; value at stack location
    call edi
    add esp, 8

    inc ecx
    add eax, 4
    jmp .scan_loop

.done:
    mov eax, ecx
    pop edi
    pop esi
    pop ebx
    pop ebp
    ret

; proc gc_memory_barrier()
; Full memory barrier for multi-threaded safety
gc_memory_barrier:
    push ebp
    mov ebp, esp
    mfence
    pop ebp
    ret

; proc gc_atomic_set(ptr_addr: ptr int32, value: int32)
; Atomically sets the value at the given address
gc_atomic_set:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]    ; ptr_addr
    mov edx, [ebp+12]   ; value
    lock xchg [eax], edx
    pop ebp
    ret

; proc gc_atomic_get(ptr_addr: ptr int32): int32
; Atomically reads the value at the given address
gc_atomic_get:
    push ebp
    mov ebp, esp
    mov eax, [ebp+8]    ; ptr_addr
    mov eax, [eax]      ; Simple read is atomic for aligned 32-bit
    pop ebp
    ret

; proc gc_atomic_cas(ptr_addr: ptr int32, expected: int32, new_val: int32): int32
; Compare-and-swap: if *ptr_addr == expected, set *ptr_addr = new_val
; Returns 1 on success, 0 on failure
gc_atomic_cas:
    push ebp
    mov ebp, esp
    push ebx

    mov ebx, [ebp+8]    ; ptr_addr
    mov eax, [ebp+12]   ; expected value
    mov ecx, [ebp+16]   ; new value

    lock cmpxchg [ebx], ecx

    jz .success
    xor eax, eax        ; Return 0 on failure
    jmp .done

.success:
    mov eax, 1          ; Return 1 on success

.done:
    pop ebx
    pop ebp
    ret
