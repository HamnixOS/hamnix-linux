# PoodillionOS Libraries

Shared libraries for OS and userspace.

## libpoo - PooScript Runtime

Core runtime library that compiled PooScript programs link against.

```c
#include <poo.h>

int main() {
    poo_echo("Hello World");
    return 0;
}
```

## libc - C Standard Library

Minimal libc implementation for userspace programs.

- String functions (strlen, strcpy, etc.)
- Memory functions (malloc, free, memcpy)
- I/O functions (printf, scanf, fopen)
- System call wrappers

## libkernel - Kernel Utilities

Helper functions for kernel modules and drivers.
