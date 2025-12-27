# BrainhairOS Synchronization Quick Reference

## Spinlock (kernel/sync.asm)

```c
// Initialize
spinlock_init(ptr lock)

// Acquire (blocking)
spinlock_lock(ptr lock)

// Release
spinlock_unlock(ptr lock)

// Try acquire (non-blocking)
int spinlock_trylock(ptr lock)  // Returns 1 if acquired, 0 if held

// Check state (debug only)
int spinlock_is_locked(ptr lock)
```

## Atomic Operations (kernel/sync.asm)

```c
// Load/Store
int32 atomic_load(ptr value)
void atomic_store(ptr value, int32 new_val)

// Arithmetic
int32 atomic_add(ptr value, int32 delta)      // Returns old value
int32 atomic_sub(ptr value, int32 delta)      // Returns old value
int32 atomic_inc(ptr value)                   // Returns new value
int32 atomic_dec(ptr value)                   // Returns new value

// Compare-and-Swap
int32 atomic_cmpxchg(ptr value, int32 expected, int32 new_val)

// Exchange
int32 atomic_swap(ptr value, int32 new_val)

// Barrier
void memory_barrier()
```

## Userland Primitives (lib/sync.bh)

### Mutex
```brainhair
var mtx: Mutex

mutex_init(addr(mtx))
mutex_lock(addr(mtx))
# ... critical section ...
mutex_unlock(addr(mtx))

if mutex_trylock(addr(mtx)) == 1:
  # ... critical section ...
  mutex_unlock(addr(mtx))
```

### Read-Write Lock
```brainhair
var rwl: RWLock

rwlock_init(addr(rwl))

# Reader
rwlock_read_lock(addr(rwl))
# ... read data ...
rwlock_read_unlock(addr(rwl))

# Writer
rwlock_write_lock(addr(rwl))
# ... modify data ...
rwlock_write_unlock(addr(rwl))
```

### Semaphore
```brainhair
var sem: Semaphore

semaphore_init(addr(sem), initial: 3, max: 10)
semaphore_wait(addr(sem))          # Decrement (blocking)
# ... use resource ...
semaphore_post(addr(sem))          # Increment

if semaphore_trywait(addr(sem)) == 1:
  # ... use resource ...
  semaphore_post(addr(sem))
```

### Condition Variable
```brainhair
var cond: CondVar
var mtx: Mutex

condvar_init(addr(cond))

# Waiter
mutex_lock(addr(mtx))
while not condition:
  condvar_wait(addr(cond), addr(mtx))  # Atomically releases mtx
# ... condition is true ...
mutex_unlock(addr(mtx))

# Signaler
mutex_lock(addr(mtx))
# ... change condition ...
condvar_signal(addr(cond))      # Wake one
# or
condvar_broadcast(addr(cond))   # Wake all
mutex_unlock(addr(mtx))
```

### Barrier
```brainhair
var bar: Barrier

barrier_init(addr(bar), thread_count: 4)

# In each thread:
# ... phase 1 work ...
barrier_wait(addr(bar))  # All threads block here until all arrive
# ... phase 2 work ...
```

### Atomic Counter
```brainhair
var counter: AtomicCounter

atomic_counter_init(addr(counter), initial: 0)
var old: int32 = atomic_counter_inc(addr(counter))
var new: int32 = atomic_counter_get(addr(counter))
discard atomic_counter_add(addr(counter), 10)
```

### Atomic Flag
```brainhair
var flag: AtomicFlag

atomic_flag_clear(addr(flag))
if atomic_flag_test_and_set(addr(flag)) == 0:
  # We got the flag (it was clear)
  # ... do one-time initialization ...
```

## Lock Ordering Rules

To avoid deadlocks:
1. Always acquire locks in the same global order
2. Document lock dependencies
3. Never acquire lock A while holding lock B if anywhere else you acquire B while holding A

Example:
```brainhair
# Global lock order: lock1 -> lock2 -> lock3

# CORRECT
mutex_lock(addr(lock1))
mutex_lock(addr(lock2))
# ... critical section ...
mutex_unlock(addr(lock2))
mutex_unlock(addr(lock1))

# WRONG - deadlock risk!
mutex_lock(addr(lock2))
mutex_lock(addr(lock1))  # Violates lock order
```

## Performance Tips

| Primitive | Best For | Avoid For |
|-----------|----------|-----------|
| Spinlock | Very short critical sections (< 100 cycles) | Long operations, I/O |
| Mutex | Medium critical sections | (Same as spinlock currently) |
| RWLock | Read-heavy workloads | Write-heavy workloads |
| Semaphore | Resource pools | Simple mutual exclusion |
| Atomic Counter | Statistics, ref counting | Complex operations |
| Atomic Flag | One-time init | Frequent operations |

## Common Patterns

### Reference Counting
```brainhair
var ref_count: AtomicCounter = 1

proc add_ref() =
  discard atomic_counter_inc(addr(ref_count))

proc release() =
  if atomic_counter_dec(addr(ref_count)) == 0:
    # Last reference, free object
    free_object()
```

### Producer-Consumer
```brainhair
var items: Semaphore
var slots: Semaphore
var lock: Mutex

proc producer() =
  semaphore_wait(addr(slots))
  mutex_lock(addr(lock))
  # ... add item ...
  mutex_unlock(addr(lock))
  semaphore_post(addr(items))

proc consumer() =
  semaphore_wait(addr(items))
  mutex_lock(addr(lock))
  # ... remove item ...
  mutex_unlock(addr(lock))
  semaphore_post(addr(slots))
```

### Lazy Initialization (Double-Checked Locking)
```brainhair
var initialized: AtomicFlag = 0
var init_lock: Mutex

proc get_instance(): ptr Instance =
  if atomic_flag_test_and_set(addr(initialized)) == 0:
    # First time
    mutex_lock(addr(init_lock))
    # ... initialize instance ...
    mutex_unlock(addr(init_lock))
  return instance
```

### Cache with RWLock
```brainhair
var cache: array[100, Entry]
var cache_lock: RWLock

proc lookup(key: int32): Entry =
  rwlock_read_lock(addr(cache_lock))
  var entry: Entry = cache[key]
  rwlock_read_unlock(addr(cache_lock))
  return entry

proc update(key: int32, value: Entry) =
  rwlock_write_lock(addr(cache_lock))
  cache[key] = value
  rwlock_write_unlock(addr(cache_lock))
```

## Syscalls (Not Yet Implemented)

| # | Name | Args |
|---|------|------|
| 210 | spinlock_init | ptr lock |
| 211 | spinlock_lock | ptr lock |
| 212 | spinlock_unlock | ptr lock |
| 213 | spinlock_trylock | ptr lock → int |
| 214 | atomic_add | ptr value, int32 delta → int32 |
| 215 | atomic_cmpxchg | ptr value, int32 expected, int32 new → int32 |
| 216 | atomic_load | ptr value → int32 |
| 217 | atomic_store | ptr value, int32 new |

## Files

- `kernel/sync.asm` - Kernel spinlock implementation (575 lines)
- `lib/sync.bh` - Userland library (397 lines)
- `docs/SYNCHRONIZATION.md` - Full documentation
- `userland/sync_test.bh` - Test program (329 lines)

## Build

```bash
# Build kernel with sync support
make microkernel

# Test (requires syscalls)
./bin/bhbuild userland/sync_test.bh bin/sync_test
./bin/sync_test
```
