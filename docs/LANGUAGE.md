# Brainhair Language Reference

Brainhair is a systems programming language designed for BrainhairOS. It compiles to native x86 assembly and provides low-level control with high-level ergonomics.

## Table of Contents

1. [Basic Syntax](#basic-syntax)
2. [Types](#types)
3. [Variables](#variables)
4. [Functions](#functions)
5. [Control Flow](#control-flow)
6. [Structs](#structs)
7. [Methods](#methods)
8. [Enums](#enums)
9. [Pattern Matching](#pattern-matching)
10. [Slices](#slices)
11. [Defer](#defer)
12. [Imports](#imports)
13. [Memory and Pointers](#memory-and-pointers)
14. [Inline Assembly](#inline-assembly)

---

## Basic Syntax

Brainhair uses Python-style indentation for blocks. Comments start with `#`.

```brainhair
# This is a comment

proc main(): int32 =
    var x: int32 = 42
    return x
```

---

## Types

### Primitive Types

| Type | Size | Description |
|------|------|-------------|
| `int8` | 1 byte | Signed 8-bit integer |
| `int16` | 2 bytes | Signed 16-bit integer |
| `int32` | 4 bytes | Signed 32-bit integer |
| `uint8` | 1 byte | Unsigned 8-bit integer |
| `uint16` | 2 bytes | Unsigned 16-bit integer |
| `uint32` | 4 bytes | Unsigned 32-bit integer |
| `bool` | 1 byte | Boolean (true/false) |
| `char` | 1 byte | Character |

### Pointer Types

```brainhair
ptr int32      # Pointer to int32
ptr uint8      # Pointer to byte (commonly used for strings)
```

### Array Types

Fixed-size arrays with compile-time known size:

```brainhair
array[10, int32]    # Array of 10 int32 values
array[256, uint8]   # Array of 256 bytes
```

### Slice Types

Fat pointers containing a pointer and length:

```brainhair
[]int32    # Slice of int32 (8 bytes: ptr + len)
[]uint8    # Slice of bytes
```

---

## Variables

### Variable Declaration

```brainhair
var name: type = value
var name: type              # Uninitialized
const name: type = value    # Immutable
```

### Examples

```brainhair
var counter: int32 = 0
var buffer: array[256, uint8]
var message: ptr uint8 = "Hello, World!"
const MAX_SIZE: int32 = 1024
```

---

## Functions

### Procedure Declaration

```brainhair
proc name(param1: type1, param2: type2): return_type =
    # body
    return value
```

### Examples

```brainhair
proc add(a: int32, b: int32): int32 =
    return a + b

proc greet(name: ptr uint8): int32 =
    print(name)
    return 0

# No return value
proc do_something(): int32 =
    return 0
```

### External Functions

Declare functions implemented in assembly:

```brainhair
extern print(msg: ptr uint8): int32
extern syscall3(num: int32, a: int32, b: int32, c: int32): int32
```

---

## Control Flow

### If/Elif/Else

```brainhair
if condition:
    # then block
elif other_condition:
    # elif block
else:
    # else block
```

### While Loop

```brainhair
while condition:
    # body
    if done:
        break
    continue
```

### For Loop (Range)

```brainhair
for i in 0..10:
    # i goes from 0 to 9
    print_int(i)
```

### For-Each Loop

```brainhair
for item in array:
    process(item)
```

---

## Structs

### Struct Definition

```brainhair
type Point = object
    x: int32
    y: int32

type Rectangle = object
    origin: Point
    width: int32
    height: int32
```

### Struct Instantiation

```brainhair
var p: Point = Point(x: 10, y: 20)
var rect: Rectangle = Rectangle(
    origin: Point(x: 0, y: 0),
    width: 100,
    height: 50
)
```

### Field Access

```brainhair
var x_val: int32 = p.x
p.y = 30
```

---

## Methods

Methods are functions with a receiver type:

```brainhair
type Point = object
    x: int32
    y: int32

# Method declaration: proc (self: ptr Type) name(params): return_type
proc (self: ptr Point) distance_squared(): int32 =
    return self.x * self.x + self.y * self.y

proc (self: ptr Point) translate(dx: int32, dy: int32): int32 =
    self.x = self.x + dx
    self.y = self.y + dy
    return 0
```

### Method Calls

```brainhair
var p: Point = Point(x: 3, y: 4)
var dist: int32 = p.distance_squared()  # Returns 25
p.translate(10, 20)
```

---

## Enums

Tagged unions with optional payloads:

### Enum Definition

```brainhair
type Option = enum
    Some(int32)
    None

type Result = enum
    Ok(int32)
    Err(int32)

type Color = enum
    Red
    Green
    Blue
```

### Creating Enum Values

```brainhair
var maybe: Option = Some(42)
var nothing: Option = None
var result: Result = Ok(100)
```

---

## Pattern Matching

The `match` expression provides exhaustive pattern matching on enums:

```brainhair
match value:
    Some(x):
        # x is bound to the payload
        return x
    None:
        return 0
```

### Example

```brainhair
proc unwrap_or(opt: Option, default: int32): int32 =
    match opt:
        Some(value):
            return value
        None:
            return default
```

---

## Slices

Slices are fat pointers containing a pointer and length.

### Creating Slices

```brainhair
var arr: array[10, int32] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
var slice: []int32 = arr[2..7]  # Elements at indices 2, 3, 4, 5, 6
```

### Slice Operations

```brainhair
var length: int32 = len(slice)  # Returns 5
var first: int32 = slice[0]     # Returns arr[2] = 3
var last: int32 = slice[4]      # Returns arr[6] = 7
```

### Built-in len()

```brainhair
len(slice)  # Returns slice length
len(array)  # Returns array size (compile-time constant)
```

---

## Defer

Execute cleanup code when function returns:

```brainhair
proc read_file(path: ptr uint8): int32 =
    var fd: int32 = open(path, 0)
    defer close(fd)  # Will execute before any return

    if fd < 0:
        return -1  # close(fd) runs here

    # ... do work ...
    return 0  # close(fd) runs here too
```

### Multiple Defers

Defers execute in LIFO (last-in, first-out) order:

```brainhair
proc example(): int32 =
    defer print("first")   # Prints third
    defer print("second")  # Prints second
    defer print("third")   # Prints first
    return 0
```

---

## Imports

Organize code across multiple files:

### Basic Import

```brainhair
import "lib/syscalls"
import "lib/string"

proc main(): int32 =
    var len: int32 = strlen("hello")
    return len
```

### Import with Alias

```brainhair
import "lib/math" as m

proc main(): int32 =
    return add(1, 2)  # Functions imported directly
```

### Import Path Resolution

1. Relative to source file
2. Relative to project root
3. `.bh` extension added automatically

---

## Memory and Pointers

### Address-Of Operator

```brainhair
var x: int32 = 42
var ptr: ptr int32 = addr(x)
```

### Pointer Dereference

```brainhair
var value: int32 = ptr[]  # Read through pointer
ptr[] = 100               # Write through pointer
```

### Pointer Arithmetic

```brainhair
var buffer: ptr uint8 = cast[ptr uint8](0xB8000)
buffer[0] = 65  # Write 'A' to first position
buffer[1] = 7   # Write attribute byte
```

### Cast Expression

```brainhair
var addr: int32 = 0xB8000
var ptr: ptr uint8 = cast[ptr uint8](addr)
```

### sizeof

```brainhair
var size: int32 = sizeof(int32)  # Returns 4
var struct_size: int32 = sizeof(Point)
```

---

## Inline Assembly

Embed raw assembly instructions:

```brainhair
proc outb(port: uint16, value: uint8): int32 =
    asm "mov dx, [ebp+8]"
    asm "mov al, [ebp+12]"
    asm "out dx, al"
    return 0

proc halt(): int32 =
    asm "cli"
    asm "hlt"
    return 0
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
| `%` | Modulo |

### Comparison

| Operator | Description |
|----------|-------------|
| `==` | Equal |
| `!=` | Not equal |
| `<` | Less than |
| `<=` | Less or equal |
| `>` | Greater than |
| `>=` | Greater or equal |

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
| `<<` | Left shift |
| `>>` | Right shift |

---

## String Literals

String literals are automatically `ptr uint8`:

```brainhair
var msg: ptr uint8 = "Hello, World!"
print(msg)
```

Escape sequences:
- `\n` - Newline
- `\t` - Tab
- `\0` - Null terminator
- `\\` - Backslash

---

## Character Literals

```brainhair
var ch: char = 'A'
var newline: char = '\n'
```

---

## Array Literals

```brainhair
var numbers: array[5, int32] = [1, 2, 3, 4, 5]
var bytes: array[3, uint8] = [0x41, 0x42, 0x43]
```

---

## Complete Example

```brainhair
import "lib/syscalls"

type Point = object
    x: int32
    y: int32

proc (self: ptr Point) magnitude_squared(): int32 =
    return self.x * self.x + self.y * self.y

type Option = enum
    Some(int32)
    None

proc safe_divide(a: int32, b: int32): Option =
    if b == 0:
        return None
    return Some(a / b)

proc main(): int32 =
    # Structs and methods
    var p: Point = Point(x: 3, y: 4)
    var mag: int32 = p.magnitude_squared()

    # Enums and pattern matching
    var result: Option = safe_divide(10, 2)
    var value: int32 = 0
    match result:
        Some(v):
            value = v
        None:
            value = -1

    # Slices
    var arr: array[5, int32] = [10, 20, 30, 40, 50]
    var slice: []int32 = arr[1..4]
    var slice_len: int32 = len(slice)

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

# Show generated assembly
./compiler/brainhair.py source.bh --asm-only
```

---

## Reserved Keywords

```
var const proc extern return if elif else while for in
break continue and or not asm cast discard addr type
object enum match defer import as true false
int8 int16 int32 uint8 uint16 uint32 bool char ptr
```
