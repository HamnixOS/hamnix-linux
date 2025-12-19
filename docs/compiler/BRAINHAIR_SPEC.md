# Brainhair Language Specification
## A Nim-like language that compiles directly to x86 machine code

**Goal:** Build BrainhairOS entirely in Brainhair, no C, no assembly (except bootloader)

---

## Language Features (Minimal Viable Subset)

### Types
```nim
# Integers
var x: int32 = 42        # 32-bit signed
var y: uint8 = 255       # 8-bit unsigned
var z: uint16 = 0x1234   # 16-bit hex

# Pointers
var ptr: ptr uint8 = cast[ptr uint8](0xB8000)
var arr: ptr UncheckedArray[uint16]

# Booleans
var flag: bool = true

# Characters
var c: char = 'A'
```

### Control Flow
```nim
# If statements
if x > 0:
  y = 1
elif x < 0:
  y = -1
else:
  y = 0

# While loops
while x < 10:
  x = x + 1

# For loops (simple range)
for i in 0..10:
  print(i)
```

### Procedures
```nim
proc add(a, b: int32): int32 =
  return a + b

proc vgaPutChar(c: char) =
  # No return value
  discard
```

### Inline Assembly
```nim
proc outb(port: uint16, val: uint8) {.inline.} =
  asm """
    mov dx, %0
    mov al, %1
    out dx, al
  """, port, val
```

### Memory Operations
```nim
# Direct memory access
ptr[0] = 0x0F41  # Write to VGA
var val = ptr[100]  # Read from memory
```

---

## Compiler Architecture

```
Source Code (.nim)
    ↓
Lexer (tokens)
    ↓
Parser (AST)
    ↓
Semantic Analysis
    ↓
x86 Code Generator
    ↓
Machine Code (.bin)
```

### Phase 1: Lexer
Input: `var x: int32 = 42`
Output:
```
[VAR, IDENT("x"), COLON, TYPE("int32"), EQUALS, NUMBER(42)]
```

### Phase 2: Parser
Generate AST:
```
VarDecl(
  name: "x",
  type: Int32,
  value: IntLiteral(42)
)
```

### Phase 3: Code Gen
Generate x86 assembly:
```asm
; var x: int32 = 42
mov dword [rbp-4], 42
```

Then assemble to machine code:
```
C7 45 FC 2A 00 00 00
```

---

## Bootstrapping Strategy

**Stage 0:** Write compiler in Python
- Input: Brainhair source
- Output: x86 machine code

**Stage 1:** Rewrite compiler in Brainhair
- Compile using Stage 0 compiler
- Now have self-hosting compiler!

**Stage 2:** Build OS
- Kernel in Brainhair
- Drivers in Brainhair
- Shell in Brainhair
- All compiled with our compiler!

---

## Implementation Phases

### Week 1: Basic Compiler
- [x] Language spec
- [ ] Lexer (Python)
- [ ] Parser (Python)
- [ ] Simple x86 codegen

### Week 2: Functions & Control Flow
- [ ] Procedure calls
- [ ] If/while/for
- [ ] Local variables

### Week 3: Memory & Pointers
- [ ] Pointer arithmetic
- [ ] Array access
- [ ] Inline assembly

### Week 4: Self-Hosting
- [ ] Rewrite compiler in Brainhair
- [ ] Bootstrap!

### Week 5+: OS Development
- [ ] Kernel
- [ ] Drivers
- [ ] Userspace

---

## Example: Hello World

**hello.nim:**
```nim
# VGA text buffer
const VGA_BUFFER = 0xB8000'u32
var vga = cast[ptr UncheckedArray[uint16]](VGA_BUFFER)

proc main() =
  let msg = "Hello from Brainhair!"
  var i = 0

  while msg[i] != '\0':
    vga[i] = uint16(msg[i]) or 0x0F00  # White on black
    i = i + 1

main()
```

**Compiles to:**
```asm
section .text
global _start

_start:
    mov edi, 0xB8000    ; VGA buffer
    lea rsi, [msg]      ; Message pointer
    xor ecx, ecx        ; i = 0

.loop:
    movzx eax, byte [rsi + rcx]  ; Load character
    test al, al
    jz .done

    or ax, 0x0F00       ; Add color
    mov [edi + rcx*2], ax
    inc ecx
    jmp .loop

.done:
    hlt

section .rodata
msg: db "Hello from Brainhair!", 0
```

---

## Why This Is Awesome

1. **No Dependencies** - Pure machine code, no libc, no runtime
2. **Fast** - Direct compilation, no C intermediary
3. **Educational** - Learn compiler design + OS dev
4. **Unique** - Your own language, your own OS
5. **Fun** - Build EVERYTHING from scratch!

---

## Next Steps

1. Write lexer (tokenize Brainhair code)
2. Write parser (build AST)
3. Generate x86 machine code
4. Compile "Hello World" kernel
5. Boot it!

**Let's build a compiler and an OS at the same time!** 🚀
