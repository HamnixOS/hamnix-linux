# Brainhair Quick Reference

A concise reference for the Brainhair programming language.

## Types

| Type | Size | Description |
|------|------|-------------|
| `int8`, `int16`, `int32`, `int64` | 1/2/4/8 bytes | Signed integers |
| `uint8`, `uint16`, `uint32`, `uint64` | 1/2/4/8 bytes | Unsigned integers |
| `bool` | 1 byte | True/False |
| `char` | 1 byte | Character |
| `str` | varies | String |
| `Ptr[T]` | 4 bytes | Pointer to T |
| `List[T]` | varies | Dynamic list |
| `Dict[K,V]` | varies | Dictionary |
| `Array[N, T]` | N * size(T) | Fixed array |
| `Optional[T]` | varies | Optional value |

## Variable Declaration

```python
x: int32 = 42              # Mutable with type
y = 100                     # Type inference
MAX: Final[int32] = 1024   # Constant
```

## Functions

```python
def add(a: int32, b: int32) -> int32:
    return a + b

extern def syscall1(num: int32, arg: int32) -> int32
```

## Control Flow

```python
# If statement
if x > 0:
    pass
elif x < 0:
    pass
else:
    pass

# While loop
while condition:
    if done:
        break
    continue

# For loop
for i in range(10):
    print_int(i)

for i in range(5, 15):
    print_int(i)
```

## Classes & Structs

```python
class Point:
    x: int32
    y: int32

    def magnitude(self) -> int32:
        return self.x * self.x + self.y * self.y

p: Point = Point(x: 10, y: 20)
```

## Enums & Pattern Matching

```python
class Option(Enum):
    Some(int32)
    None

match value:
    Some(x):
        return x
    None:
        return 0
```

## Memory Operations

```python
# Pointer from address
vga: Ptr[uint16] = Ptr[uint16](0xB8000)
vga[0] = 0x0F41

# Address-of
x: int32 = 42
p: Ptr[int32] = addr(x)

# Cast
ptr: Ptr[uint8] = cast[Ptr[uint8]](addr)

# Pointer to integer
addr_val: int32 = int(ptr)

# Size of type
size: int32 = sizeof(Point)
```

## Operators

| Category | Operators |
|----------|-----------|
| Arithmetic | `+` `-` `*` `/` `//` `%` `**` |
| Comparison | `==` `!=` `<` `<=` `>` `>=` |
| Logical | `and` `or` `not` |
| Bitwise | `&` `\|` `^` `~` `<<` `>>` |
| Assignment | `+=` `-=` `*=` `/=` `&=` `\|=` `^=` `<<=` `>>=` |

## Inline Assembly

```python
def outb(port: uint16, value: uint8):
    asm("mov dx, [ebp+8]")
    asm("mov al, [ebp+12]")
    asm("out dx, al")
```

## Imports

```python
from lib.syscalls import *
from lib.syscalls import write, read
import lib.math as m
```

## Decorators

```python
@inline
def fast_add(a: int32, b: int32) -> int32:
    return a + b

@packed
class NetworkHeader:
    src: uint32
    dst: uint32
```

## Common Syscall Wrappers

```python
from lib.syscalls import *

write(STDOUT, "Hello\n", 6)
fd: int32 = open("/tmp/file", O_RDONLY, 0)
n: int32 = read(fd, buffer, 1024)
close(fd)
exit(0)
```

## Compiler Usage

```bash
# Basic compilation
./compiler/brainhair.py source.bh -o output

# Compile and run
./compiler/brainhair.py source.bh -o output --run

# 64-bit mode
./compiler/brainhair.py source.bh -o output --x86_64

# Kernel mode (no _start)
./compiler/brainhair.py source.bh -o output.o --kernel

# View assembly
./compiler/brainhair.py source.bh --asm-only

# Skip checks
./compiler/brainhair.py source.bh -o output --no-typecheck --no-ownership --no-lifetimes
```

## Bootstrap Testing

```bash
# Full bootstrap (compile compiler, test, build OS)
./bootstrap.sh

# Skip OS build
./bootstrap.sh --skip-os

# Verbose output
./bootstrap.sh --verbose

# Parallel builds
./bootstrap.sh --parallel 8
```

## Example Program

```python
from lib.syscalls import *

class Counter:
    value: int32

    def increment(self):
        self.value += 1

    def get(self) -> int32:
        return self.value

def main() -> int32:
    c: Counter = Counter(value: 0)

    for i in range(10):
        c.increment()

    result: int32 = c.get()

    if result == 10:
        print("Success!\n")
    else:
        print("Error!\n")

    return 0
```
