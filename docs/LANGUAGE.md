# Brainhair Language Reference

Brainhair is a systems programming language with Python syntax, designed for BrainhairOS. It compiles to native x86/x86_64 assembly and provides low-level control with Python's familiar ergonomics.

## Table of Contents

1. [Basic Syntax](#basic-syntax)
2. [Types](#types)
3. [Variables](#variables)
4. [Functions](#functions)
5. [Control Flow](#control-flow)
6. [Classes](#classes)
7. [Methods](#methods)
8. [Enums](#enums)
9. [Pattern Matching](#pattern-matching)
10. [Lists and Slices](#lists-and-slices)
11. [Defer and Context Managers](#defer-and-context-managers)
12. [Imports](#imports)
13. [Memory and Pointers](#memory-and-pointers)
14. [Inline Assembly](#inline-assembly)
15. [Decorators](#decorators)

---

## Basic Syntax

Brainhair uses Python-style indentation for blocks. Comments start with `#`.

```python
# This is a comment

def main() -> int32:
    x: int32 = 42
    return x
```

---

## Types

### Primitive Types

| Type | Size | Description |
|------|------|-------------|
| `int8` | 1 byte | Signed 8-bit integer |
| `int16` | 2 bytes | Signed 16-bit integer |
| `int32` | 4 bytes | Signed 32-bit integer (alias: `int`) |
| `int64` | 8 bytes | Signed 64-bit integer |
| `uint8` | 1 byte | Unsigned 8-bit integer |
| `uint16` | 2 bytes | Unsigned 16-bit integer |
| `uint32` | 4 bytes | Unsigned 32-bit integer |
| `uint64` | 8 bytes | Unsigned 64-bit integer |
| `bool` | 1 byte | Boolean (True/False) |
| `char` | 1 byte | Character |
| `str` | varies | String type |

### Pointer Types

```python
Ptr[int32]      # Pointer to int32
Ptr[uint8]      # Pointer to byte (commonly used for raw strings)
```

### Collection Types

```python
List[int32]         # Growable list of int32
Dict[str, int32]    # Dictionary mapping strings to int32
Tuple[int32, str]   # Fixed tuple of (int32, str)
Optional[int32]     # Either int32 or None
```

### Array Types

Fixed-size arrays with compile-time known size:

```python
Array[10, int32]    # Array of 10 int32 values
Array[256, uint8]   # Array of 256 bytes
```

---

## Variables

### Variable Declaration

```python
name: Type = value        # Mutable variable with type annotation
name = value              # Mutable variable with type inference
name: Final[Type] = value # Immutable constant
```

### Examples

```python
counter: int32 = 0
buffer: Array[256, uint8]
message: Ptr[uint8] = "Hello, World!"
MAX_SIZE: Final[int32] = 1024
```

---

## Functions

### Function Declaration

```python
def name(param1: Type1, param2: Type2) -> ReturnType:
    # body
    return value
```

### Examples

```python
def add(a: int32, b: int32) -> int32:
    return a + b

def greet(name: Ptr[uint8]) -> int32:
    print(name)
    return 0

# No return value (implicit None)
def do_something():
    pass
```

### External Functions

Declare functions implemented in assembly:

```python
extern def print(msg: Ptr[uint8]) -> int32
extern def syscall3(num: int32, a: int32, b: int32, c: int32) -> int32
```

---

## Control Flow

### If/Elif/Else

```python
if condition:
    # then block
elif other_condition:
    # elif block
else:
    # else block
```

### Comparison Chaining

Python-style comparison chaining:

```python
if 0 <= x < 100:
    # x is between 0 and 99
```

### While Loop

```python
while condition:
    # body
    if done:
        break
    continue
```

### For Loop (Range)

```python
for i in range(10):
    # i goes from 0 to 9
    print_int(i)

for i in range(5, 15):
    # i goes from 5 to 14
    print_int(i)
```

### For-Each Loop

```python
for item in collection:
    process(item)
```

---

## Classes

### Class Definition

```python
class Point:
    x: int32
    y: int32

class Rectangle:
    origin: Point
    width: int32
    height: int32
```

### Class Instantiation

```python
p: Point = Point(x: 10, y: 20)
rect: Rectangle = Rectangle(
    origin: Point(x: 0, y: 0),
    width: 100,
    height: 50
)
```

### Field Access

```python
x_val: int32 = p.x
p.y = 30
```

---

## Methods

Methods are defined inside class bodies with `self` as the first parameter:

```python
class Point:
    x: int32
    y: int32

    def distance_squared(self) -> int32:
        return self.x * self.x + self.y * self.y

    def translate(self, dx: int32, dy: int32):
        self.x += dx
        self.y += dy
```

### Method Calls

```python
p: Point = Point(x: 3, y: 4)
dist: int32 = p.distance_squared()  # Returns 25
p.translate(10, 20)
```

---

## Enums

Tagged unions with optional payloads:

### Enum Definition

```python
class Option(Enum):
    Some(int32)
    None

class Result(Enum):
    Ok(int32)
    Err(int32)

class Color(Enum):
    Red
    Green
    Blue
```

### Creating Enum Values

```python
maybe: Option = Some(42)
nothing: Option = None
result: Result = Ok(100)
```

---

## Pattern Matching

The `match` expression provides exhaustive pattern matching on enums:

```python
match value:
    Some(x):
        # x is bound to the payload
        return x
    None:
        return 0
```

### Example

```python
def unwrap_or(opt: Option, default: int32) -> int32:
    match opt:
        Some(value):
            return value
        None:
            return default
```

---

## Lists and Slices

### List Literals

```python
nums: List[int32] = [1, 2, 3, 4, 5]
empty: List[str] = []
```

### Dict Literals

```python
table: Dict[str, int32] = {"foo": 1, "bar": 2}
```

### Slice Operations

```python
arr: Array[10, int32] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
slice: List[int32] = arr[2..7]  # Elements at indices 2, 3, 4, 5, 6

length: int32 = len(slice)  # Returns 5
first: int32 = slice[0]     # Returns 3
```

---

## Defer and Context Managers

### Defer Statement

Execute cleanup code when function returns:

```python
def read_file(path: Ptr[uint8]) -> int32:
    fd: int32 = open(path, 0)
    defer close(fd)  # Will execute before any return

    if fd < 0:
        return -1  # close(fd) runs here

    # ... do work ...
    return 0  # close(fd) runs here too
```

### Context Managers (with statement)

```python
with open("/etc/hosts", "r") as f:
    data = f.read()
# f automatically closed

with lock(mutex):
    # critical section
# mutex automatically released
```

---

## Imports

### Python-style Imports

```python
from lib.syscalls import *
from lib.syscalls import write, read, close
import lib.math as m
```

### Import Path Resolution

1. Relative to source file
2. Relative to project root
3. `.bh` extension added automatically

---

## Memory and Pointers

### Address-Of Operator

```python
x: int32 = 42
p: Ptr[int32] = addr(x)
```

### Pointer Construction

```python
# Create pointer from address
vga: Ptr[uint16] = Ptr[uint16](0xB8000)
vga[0] = 0x0F41
```

### Pointer Dereference

```python
value: int32 = p[0]  # Read through pointer
p[0] = 100           # Write through pointer
```

### Cast Expression

```python
addr: int32 = 0xB8000
p: Ptr[uint8] = cast[Ptr[uint8]](addr)

# Or use the Ptr constructor directly
p: Ptr[uint8] = Ptr[uint8](addr)
```

### int() for pointer-to-integer conversion

```python
p: Ptr[uint8] = addr(buffer)
addr_value: int32 = int(p)  # Get address as integer
```

### sizeof

```python
size: int32 = sizeof(int32)  # Returns 4
struct_size: int32 = sizeof(Point)
```

---

## Inline Assembly

Embed raw assembly instructions:

```python
def outb(port: uint16, value: uint8) -> int32:
    asm("mov dx, [ebp+8]")
    asm("mov al, [ebp+12]")
    asm("out dx, al")
    return 0

def halt() -> int32:
    asm("cli")
    asm("hlt")
    return 0
```

---

## Decorators

### @inline

Mark functions for inline expansion:

```python
@inline
def fast_add(a: int32, b: int32) -> int32:
    return a + b
```

### @packed

Create tightly packed structs (no padding):

```python
@packed
class NetworkHeader:
    src: uint32
    dst: uint32
    flags: uint16
```

### @syscall

Mark functions as syscall wrappers:

```python
@syscall(1)
def sys_exit(code: int32):
    pass
```

---

## Operators

### Arithmetic

| Operator | Description |
|----------|-------------|
| `+` | Addition |
| `-` | Subtraction |
| `*` | Multiplication |
| `/` | Division |
| `//` | Integer Division |
| `%` | Modulo |
| `**` | Power |

### Compound Assignment

| Operator | Description |
|----------|-------------|
| `+=` | Add and assign |
| `-=` | Subtract and assign |
| `*=` | Multiply and assign |
| `/=` | Divide and assign |
| `//=` | Integer divide and assign |
| `%=` | Modulo and assign |
| `&=` | Bitwise AND and assign |
| `\|=` | Bitwise OR and assign |
| `^=` | Bitwise XOR and assign |
| `<<=` | Left shift and assign |
| `>>=` | Right shift and assign |

### Comparison

| Operator | Description |
|----------|-------------|
| `==` | Equal |
| `!=` | Not equal |
| `<` | Less than |
| `<=` | Less or equal |
| `>` | Greater than |
| `>=` | Greater or equal |
| `is` | Identity |
| `is not` | Non-identity |

### Logical

| Operator | Description |
|----------|-------------|
| `and` | Logical AND |
| `or` | Logical OR |
| `not` | Logical NOT |

### Bitwise

| Operator | Description |
|----------|-------------|
| `\|` | Bitwise OR |
| `&` | Bitwise AND |
| `^` | Bitwise XOR |
| `~` | Bitwise NOT |
| `<<` | Left shift |
| `>>` | Right shift |

---

## String Literals

```python
msg: Ptr[uint8] = "Hello, World!"
print(msg)
```

### F-strings (Format Strings)

```python
name: str = "Alice"
count: int32 = 5
msg = f"User {name} has {count} items"
```

### Escape Sequences

- `\n` - Newline
- `\t` - Tab
- `\0` - Null terminator
- `\\` - Backslash
- `\xNN` - Hex byte

---

## Complete Example

```python
from lib.syscalls import *

class Point:
    x: int32
    y: int32

    def magnitude_squared(self) -> int32:
        return self.x * self.x + self.y * self.y

class Option(Enum):
    Some(int32)
    None

def safe_divide(a: int32, b: int32) -> Option:
    if b == 0:
        return None
    return Some(a / b)

def main() -> int32:
    # Classes and methods
    p: Point = Point(x: 3, y: 4)
    mag: int32 = p.magnitude_squared()

    # Enums and pattern matching
    result: Option = safe_divide(10, 2)
    value: int32 = 0
    match result:
        Some(v):
            value = v
        None:
            value = -1

    # Lists
    arr: List[int32] = [10, 20, 30, 40, 50]
    slice: List[int32] = arr[1..4]
    slice_len: int32 = len(slice)

    # Compound assignment
    value += 10

    # Defer
    defer print("Goodbye!\n")

    return value + slice_len
```

---

## Compilation

```bash
# Compile to executable
./compiler/brainhair.py source.bh -o output

# Compile and run
./compiler/brainhair.py source.bh -o output --run

# Kernel mode (no _start, exports main)
./compiler/brainhair.py source.bh -o output.o --kernel

# Generate 64-bit code
./compiler/brainhair.py source.bh -o output --x86_64

# Show generated assembly
./compiler/brainhair.py source.bh --asm-only

# Skip optional passes
./compiler/brainhair.py source.bh -o output --no-typecheck --no-ownership --no-lifetimes
```

---

## Self-Hosting

The Brainhair compiler is **self-hosting** - it can compile its own components to native x86 executables!

### Bootstrap Process

The compiler components (lexer.py, parser.py, codegen_x86.py) are written in Python-style Brainhair syntax and can be compiled to native code:

```bash
# Run the bootstrap script
./bootstrap.sh

# This will:
# 1. Compile lexer.py, parser.py, codegen_x86.py to native x86
# 2. Run unit tests to verify correctness
# 3. Build all OS userland programs
```

### Bootstrap Script Options

```bash
./bootstrap.sh              # Full bootstrap (compile, test, build OS)
./bootstrap.sh --skip-os    # Skip OS build, just test compiler
./bootstrap.sh --verbose    # Show detailed output
./bootstrap.sh --parallel 8 # Build 8 programs in parallel
```

### Python/Brainhair Interoperability

The compiler can process both `.bh` and `.py` files. Python files with Brainhair-compatible syntax compile directly to x86:

```python
# This Python-style file compiles to native x86!
class Token:
    type: str
    value: str
    line: int32

def tokenize(source: str) -> List[Token]:
    tokens: List[Token] = []
    # ... implementation
    return tokens
```

### Unit Tests

Unit tests verify compiler correctness:

```
tests/compiler_unit/
├── test_01_basic_io.bh        # Basic I/O operations
├── test_02_struct_basic.bh    # Struct definitions
├── test_03_strlen.bh          # String length
├── test_04_struct_multifield.bh # Multi-field structs
├── test_05_loops_conditions.bh  # Loops and conditions
├── test_06_token_counter.bh   # Token counting
├── test_07_global_string.bh   # Global strings
└── test_self_host_lexer.py    # Lexer self-hosting test
```

---

## Reserved Keywords

```
def class from import as return if elif else while for in
break continue pass with raise try except finally
and or not is async await yield lambda
extern asm defer match
True False None
Final Ptr List Dict Tuple Optional Enum
int8 int16 int32 int64 uint8 uint16 uint32 uint64
float32 float64 bool char str bytes int float
```
