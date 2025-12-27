# BrainhairOS Synchronization Primitives

This document describes the synchronization primitives available in BrainhairOS for building multi-threaded and SMP-safe applications.

## Overview

BrainhairOS provides a comprehensive set of synchronization primitives as the foundation for SMP (Symmetric Multi-Processing) support. These primitives are implemented in two layers:

1. **Kernel Layer** (`kernel/sync.asm`) - Low-level atomic operations and spinlocks
2. **Userland Layer** (`lib/sync.bh`) - High-level synchronization constructs

## Files

- `kernel/sync.asm` - Assembly implementation of atomic operations and spinlocks (784 lines)
- `lib/sync.bh` - Brainhair library for userland synchronization (424 lines)
- `userland/sync_test.bh` - Test program demonstrating all synchronization primitives
- `userland/thread_test.bh` - Multi-threaded test using shared counter

## Kernel-Level Primitives (kernel/sync.asm)

### Spinlocks

Spinlocks are the most basic synchronization primitive, suitable for protecting short critical sections in kernel code or SMP environments.

#### Functions

```asm
; Initialize a spinlock
spinlock_init(lock: ptr)

; Acquire a spinlock (blocking)
; Spins until lock is acquired using PAUSE instruction
spinlock_lock(lock: ptr)

; Release a spinlock
; Uses memory barrier to ensure visibility
spinlock_unlock(lock: ptr)

; Try to acquire a spinlock (non-blocking)
; Returns: 1 if acquired, 0 if already held
spinlock_trylock(lock: ptr): int

; Check if a spinlock is currently locked (debugging only)
; Returns: 1 if locked, 0 if unlocked
spinlock_is_locked(lock: ptr): int
```

#### Implementation Details

- **Atomicity**: Uses x86 `LOCK CMPXCHG` instruction for atomic compare-and-swap
- **Efficiency**: Uses `PAUSE` instruction in spin loop to reduce power consumption and bus traffic
- **Memory Barriers**: Uses `LOCK OR` or `MFENCE` for full memory fence
- **Statistics**: Optional statistics tracking (total locks, contentions)

#### Memory Barriers

```asm
; Full memory barrier
memory_barrier()
```

### Atomic Operations

Atomic operations provide lock-free synchronization for simple operations.

#### Functions

```asm
; Atomically load a 32-bit value
atomic_load(ptr: ptr): int32

; Atomically store a 32-bit value
atomic_store(ptr: ptr, value: int32)

; Atomically add and return old value
atomic_add(ptr: ptr, value: int32): int32

; Atomically subtract and return old value
atomic_sub(ptr: ptr, value: int32): int32

; Atomically increment and return new value
atomic_inc(ptr: ptr): int32

; Atomically decrement and return new value
atomic_dec(ptr: ptr): int32

; Atomic compare-and-swap
; If *ptr == expected, set *ptr = new_value and return expected
; Otherwise, return current *ptr value
atomic_cmpxchg(ptr: ptr, expected: int32, new_value: int32): int32

; Atomic exchange (swap)
; Atomically swap value and return old value
atomic_swap(ptr: ptr, new_value: int32): int32
```

#### Implementation Details

- **x86 Instructions**: Uses `LOCK XADD`, `LOCK INC/DEC`, `LOCK CMPXCHG`, `XCHG`
- **Memory Ordering**: All operations have full memory barrier semantics
- **Alignment**: Assumes naturally aligned 32-bit values

### Statistics

Spinlock statistics can be enabled for debugging and performance analysis:

```asm
spinlock_enable_stats()
spinlock_disable_stats()
spinlock_get_stats(total_locks: ptr, total_contentions: ptr)
spinlock_reset_stats()
```

## Userland Primitives (lib/sync.bh)

### Spinlock

Basic userland wrapper around kernel spinlocks.

```brainhair
type Spinlock = int32

spinlock_init(lock: ptr Spinlock)
spinlock_lock(lock: ptr Spinlock)
spinlock_unlock(lock: ptr Spinlock)
spinlock_trylock(lock: ptr Spinlock): int32
```

**Use Case**: Protecting very short critical sections in userland, or when sleeping is not an option.

**Warning**: Spinlocks waste CPU cycles. Use mutexes for longer critical sections.

### Mutex

A mutual exclusion lock that should eventually support sleeping (currently implemented as spinlock).

```brainhair
type Mutex = record
  lock: Spinlock
  owner: int32      # Thread ID of owner
  count: int32      # Recursion count

mutex_init(mtx: ptr Mutex)
mutex_lock(mtx: ptr Mutex)
mutex_unlock(mtx: ptr Mutex)
mutex_trylock(mtx: ptr Mutex): int32
```

**Use Case**: Protecting critical sections in multi-threaded applications.

**TODO**: Implement futex-style sleeping locks for better performance.

### Read-Write Lock

Allows multiple readers OR one writer.

```brainhair
type RWLock = record
  lock: Spinlock
  readers: int32
  writer: int32
  waiting_writers: int32

rwlock_init(rwl: ptr RWLock)
rwlock_read_lock(rwl: ptr RWLock)
rwlock_read_unlock(rwl: ptr RWLock)
rwlock_write_lock(rwl: ptr RWLock)
rwlock_write_unlock(rwl: ptr RWLock)
```

**Use Case**: Protecting data structures that are read frequently but written rarely (e.g., caches, lookup tables).

**Algorithm**: Writers have priority over new readers to prevent writer starvation.

### Semaphore

A counting semaphore for resource management.

```brainhair
type Semaphore = record
  lock: Spinlock
  count: int32      # Available resources
  max: int32        # Maximum count

semaphore_init(sem: ptr Semaphore, initial: int32, max_count: int32)
semaphore_wait(sem: ptr Semaphore)
semaphore_trywait(sem: ptr Semaphore): int32
semaphore_post(sem: ptr Semaphore)
semaphore_getvalue(sem: ptr Semaphore): int32
```

**Use Case**: Limiting access to a fixed number of resources (e.g., thread pool, connection pool).

### Condition Variable

For waiting on arbitrary conditions (requires associated mutex).

```brainhair
type CondVar = record
  lock: Spinlock
  waiters: int32

condvar_init(cond: ptr CondVar)
condvar_wait(cond: ptr CondVar, mtx: ptr Mutex)
condvar_signal(cond: ptr CondVar)
condvar_broadcast(cond: ptr CondVar)
```

**Use Case**: Producer-consumer queues, event notification.

**Warning**: Current implementation is simplified and inefficient. Proper futex-style implementation needed.

### Barrier

Synchronization point where all threads must arrive before any can proceed.

```brainhair
type Barrier = record
  lock: Spinlock
  threshold: int32  # Number of threads that must wait
  count: int32      # Current number of waiting threads
  generation: int32 # Generation number (for reuse)

barrier_init(bar: ptr Barrier, thread_count: int32)
barrier_wait(bar: ptr Barrier)
```

**Use Case**: Parallel algorithms with phases (e.g., parallel sort, matrix multiplication).

### Atomic Flag

Simple lock-free boolean flag.

```brainhair
type AtomicFlag = int32

atomic_flag_clear(flag: ptr AtomicFlag)
atomic_flag_test_and_set(flag: ptr AtomicFlag): int32
```

**Use Case**: Simple one-time initialization, lock-free algorithms.

### Atomic Counter

Lock-free counter for statistics and reference counting.

```brainhair
type AtomicCounter = int32

atomic_counter_init(counter: ptr AtomicCounter, initial: int32)
atomic_counter_inc(counter: ptr AtomicCounter): int32
atomic_counter_dec(counter: ptr AtomicCounter): int32
atomic_counter_get(counter: ptr AtomicCounter): int32
atomic_counter_set(counter: ptr AtomicCounter, value: int32)
atomic_counter_add(counter: ptr AtomicCounter, value: int32): int32
```

**Use Case**: Reference counting, statistics, progress tracking.

## Usage Examples

### Example 1: Protecting a Shared Counter

```brainhair
import "lib/sync"

var counter: int32 = 0
var counter_lock: Mutex

proc increment_counter() =
  mutex_lock(addr(counter_lock))
  counter = counter + 1
  mutex_unlock(addr(counter_lock))

proc main(): int32 =
  mutex_init(addr(counter_lock))

  # Create threads that call increment_counter()
  # ...

  return 0
```

### Example 2: Reader-Writer Pattern

```brainhair
import "lib/sync"

var cache_data: array[100, int32]
var cache_lock: RWLock

proc read_cache(index: int32): int32 =
  rwlock_read_lock(addr(cache_lock))
  var value: int32 = cache_data[index]
  rwlock_read_unlock(addr(cache_lock))
  return value

proc update_cache(index: int32, value: int32) =
  rwlock_write_lock(addr(cache_lock))
  cache_data[index] = value
  rwlock_write_unlock(addr(cache_lock))
```

### Example 3: Atomic Operations

```brainhair
import "lib/sync"

var ref_count: AtomicCounter = 0

proc add_reference() =
  discard atomic_counter_inc(addr(ref_count))

proc remove_reference(): int32 =
  var new_count: int32 = atomic_counter_dec(addr(ref_count))
  return new_count
```

### Example 4: Producer-Consumer with Semaphore

```brainhair
import "lib/sync"

var items_available: Semaphore
var slots_available: Semaphore
var queue_lock: Mutex

proc producer() =
  while 1 == 1:
    # Produce item
    var item: int32 = produce_item()

    # Wait for empty slot
    semaphore_wait(addr(slots_available))

    mutex_lock(addr(queue_lock))
    # Add to queue
    mutex_unlock(addr(queue_lock))

    # Signal item available
    semaphore_post(addr(items_available))

proc consumer() =
  while 1 == 1:
    # Wait for item
    semaphore_wait(addr(items_available))

    mutex_lock(addr(queue_lock))
    # Remove from queue
    var item: int32 = dequeue()
    mutex_unlock(addr(queue_lock))

    # Signal slot available
    semaphore_post(addr(slots_available))

    # Consume item
    consume_item(item)
```

## Syscall Interface

The following syscalls need to be implemented in the kernel to expose synchronization primitives to userland:

| Syscall # | Name | Description |
|-----------|------|-------------|
| 210 | SYS_spinlock_init | Initialize a spinlock |
| 211 | SYS_spinlock_lock | Acquire a spinlock |
| 212 | SYS_spinlock_unlock | Release a spinlock |
| 213 | SYS_spinlock_trylock | Try to acquire a spinlock |
| 214 | SYS_atomic_add | Atomic add operation |
| 215 | SYS_atomic_cmpxchg | Atomic compare-and-swap |
| 216 | SYS_atomic_load | Atomic load operation |
| 217 | SYS_atomic_store | Atomic store operation |

**Note**: These syscalls are defined in `lib/sync.bh` but not yet implemented in the kernel ISR handler.

## Performance Considerations

### Spinlocks vs Mutexes

- **Spinlocks**: Good for very short critical sections (< 100 cycles). Waste CPU if held long.
- **Mutexes**: Good for longer critical sections. Should sleep when contended (not yet implemented).

### Memory Barriers

- All atomic operations include full memory barriers
- May be overkill for some use cases (e.g., statistics)
- Consider relaxed atomics in the future for performance

### Cache Line Bouncing

- Spinlocks cause cache line bouncing in SMP systems
- Keep critical sections short
- Use RWLocks when appropriate
- Consider lock-free algorithms for high contention

### Lock Ordering

To avoid deadlocks:
1. Always acquire locks in the same order
2. Document lock ordering in comments
3. Use trylock for optional locking
4. Avoid holding multiple locks when possible

## Testing

### Compile Tests

```bash
# Build the synchronization test program
./bin/bhbuild userland/sync_test.bh bin/sync_test

# Run the test
./bin/sync_test
```

### Multi-threaded Test

```bash
# Build and run the threading test (demonstrates shared counter)
./bin/bhbuild userland/thread_test.bh bin/thread_test
./bin/thread_test
```

## Future Work

### High Priority

1. **Implement syscalls 210-217** in kernel ISR handler
2. **Futex-style sleeping locks** for efficient blocking
3. **Per-CPU variables** for SMP bootstrap
4. **Atomic operations in Brainhair** (`atomic` keyword)

### Medium Priority

5. **Lock-free data structures** (queues, stacks, lists)
6. **RCU (Read-Copy-Update)** for high-performance readers
7. **Hazard pointers** for safe memory reclamation
8. **Lock statistics and debugging** (lock contention profiling)

### Low Priority

9. **Priority inheritance** for mutexes (avoid priority inversion)
10. **Adaptive spinning** (spin briefly before sleeping)
11. **Ticket locks** (fair spinlocks)
12. **Relaxed atomics** (weaker memory ordering for performance)

## References

- Intel x86 Architecture Manual (Volume 3, Chapter 8: Multi-Processor Management)
- Linux futex(2) man page
- "The Art of Multiprocessor Programming" by Herlihy & Shavit
- "Linux Kernel Development" by Robert Love (Chapter 9: Kernel Synchronization)

## Architecture Notes

### x86 Memory Ordering

x86 provides strong memory ordering guarantees:
- Loads are not reordered with other loads
- Stores are not reordered with other stores
- Stores are not reordered with earlier loads
- Loads may be reordered with earlier stores

However:
- For true SMP safety, we use explicit barriers (`MFENCE`, `LOCK` prefix)
- `LOCK` prefix provides full memory barrier on modern x86

### SMP Considerations

For true SMP support, we need:
1. Per-CPU data structures (GDT, IDT, TSS, stack)
2. Inter-Processor Interrupts (IPI)
3. SMP-safe memory allocator
4. Lock all kernel data structures
5. Per-CPU run queues for scheduler

These are the next steps after basic spinlock support (Phase 3.3-3.4).

## License

Part of BrainhairOS, a custom operating system project.
