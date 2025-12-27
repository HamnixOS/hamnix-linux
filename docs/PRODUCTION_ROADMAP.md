# BrainhairOS: Roadmap to a Mature Operating System

Transform BrainhairOS from a hobby project into a capable, general-purpose operating system.

---

## Phase 1: 64-bit Architecture

### 1.1 Port to x86_64
- [ ] Long mode bootloader (switch from protected mode)
- [ ] 4-level page tables (PML4/PDPT/PD/PT)
- [ ] 64-bit register usage throughout kernel assembly
- [ ] Update Brainhair compiler for x86_64 codegen
- [ ] syscall/sysret instead of int 0x80
- [ ] 64-bit pointers in type system
- [ ] Update basm for x86_64 instruction encoding
- [ ] Update bhlink for ELF64
- [ ] Port all userland utilities

### 1.2 Memory Architecture
- [ ] Per-process virtual address spaces (proper isolation)
- [ ] Demand paging (lazy allocation)
- [ ] Copy-on-write fork()
- [ ] Memory-mapped files
- [ ] Shared memory regions
- [ ] Kernel/user address space split

---

## Phase 2: Garbage Collection

### 2.1 GC Runtime Design ✓ COMPLETE
- [x] Choose GC strategy (mark-sweep, copying, or generational) - **Mark-sweep implemented**
- [x] Implement object headers (type info, GC metadata) - **16-byte headers with mark bit, type, size, next/prev**
- [x] Add heap allocator with GC awareness - **gc_alloc() with free list reuse**
- [x] Implement root scanning (stack, globals, registers) - **Global root registration via gc_register_root()**
- [ ] Add write barriers for generational GC (if used) - *Deferred: not needed for mark-sweep*

**Implementation Notes:**
- `lib/gc.bh` - Main GC library with mark-sweep collector
- `lib/gc_primitives.asm` - Low-level assembly for stack scanning, atomics
- Object header: mark_and_type (4B), size (4B), next (4B), prev (4B)
- Heap allocated via mmap2, 4MB default size
- Free list for O(1) reuse of freed objects
- Known limitations: Stack scanning disabled due to bounds detection issues

### 2.2 Language Integration
- [ ] Add `gc` keyword or automatic for heap objects
- [ ] Distinguish stack vs heap allocation in compiler
- [ ] Add reference types vs value types
- [ ] Implement finalizers/destructors
- [ ] Add weak references
- [x] Optional: Keep `ptr` for manual memory (FFI, kernel) - **ptr types work alongside GC**

### 2.3 GC Modes
- [x] Stop-the-world collector (simple, first pass) - **gc_collect() implemented**
- [ ] Incremental collector (reduce pause times)
- [ ] Concurrent collector (run alongside mutator)
- [ ] Per-thread heaps option for parallelism

### 2.4 Tuning & Diagnostics
- [x] GC statistics and logging - **gc_get_heap_used(), gc_get_object_count(), etc.**
- [x] Configurable heap sizes - **GC_DEFAULT_HEAP_SIZE constant**
- [x] Explicit GC trigger API - **gc_collect(), gc_enable(), gc_disable()**
- [ ] Memory profiler integration

---

## Phase 3: Multi-Core / SMP

### 3.1 Bootstrap
- [ ] Detect CPU count via ACPI/MP tables
- [ ] Start Application Processors (APs) via SIPI
- [ ] Per-CPU GDT, IDT, TSS, kernel stack
- [ ] Per-CPU variables and current-CPU accessor

### 3.2 Synchronization
- [x] Spinlocks with proper memory barriers - **IMPLEMENTED**
- [x] Atomic operations (load, store, add, cmpxchg, swap, inc, dec) - **IMPLEMENTED**
- [x] Mutex wrappers (using spinlocks) - **IMPLEMENTED**
- [x] Read-write locks - **IMPLEMENTED**
- [x] Semaphores - **IMPLEMENTED**
- [x] Condition variables (basic) - **IMPLEMENTED**
- [x] Barriers - **IMPLEMENTED**
- [x] Proper sleeping mutexes (futex-style syscalls) - **IMPLEMENTED**
- [ ] Atomic operations in Brainhair (`atomic` keyword)
- [ ] Lock-free data structures (queues, lists)

**Implementation Notes:**
- `kernel/sync.asm` - Low-level spinlock primitives (784 lines)
- `kernel/futex.asm` - Fast userspace mutex support (503 lines)
- `lib/sync.bh` - Userland synchronization library (600+ lines)
- Spinlock functions: init, lock, unlock, trylock, is_locked
- Atomic operations: load, store, add, sub, inc, dec, cmpxchg, swap
- Uses LOCK prefix for atomicity, PAUSE for spin efficiency, MFENCE for barriers
- Futex syscalls 250-252: futex_wait, futex_wake, futex_requeue
- FutexMutex, FutexSemaphore, FutexCondVar - sleeping primitives
- Once control for thread-safe initialization
- Higher-level primitives: Mutex, RWLock, Semaphore, CondVar, Barrier, AtomicFlag, AtomicCounter
- Statistics tracking: enable/disable stats, get/reset stats
- Foundation ready for SMP support
- TODO: Add syscalls (210-217) to expose kernel spinlocks to userland

### 3.3 SMP Scheduler
- [ ] Per-CPU run queues
- [ ] Work stealing between CPUs
- [ ] CPU affinity support
- [ ] Load balancing
- [ ] Real-time priority classes

### 3.4 Kernel SMP Safety
- [ ] Lock all shared data structures
- [ ] SMP-safe memory allocator
- [ ] SMP-safe filesystem
- [ ] SMP-safe network stack
- [ ] Inter-Processor Interrupts (IPI)

---

## Phase 4: Process & Resource Management

### 4.1 Expand Process Support
- [ ] Dynamic process table (not fixed 64)
- [ ] Target: 32,768+ processes
- [x] Process groups and sessions - **IMPLEMENTED: setpgid, getpgid, setsid, getsid**
- [x] Job control (foreground/background) - **Foundation ready: PCB_PGRP, PCB_SID, PCB_CTTY**
- [ ] PID namespaces (isolation)

**Implementation Notes:**
- Added PCB fields: PCB_PGRP (116), PCB_SID (120), PCB_CTTY (124)
- Syscalls 76-79: setpgid, getpgid, setsid, getsid
- POSIX-compliant semantics for session and process group management
- kernel/process.asm lines 51-53, 239-242, 1316-1533
- Enables shell job control (foreground/background processes, signal delivery to process groups)

### 4.2 Threads
- [x] Kernel threads - **IMPLEMENTED**
- [x] User-space threads (1:1 model) - **IMPLEMENTED**
- [x] Thread-local storage (TLS) - **IMPLEMENTED**
- [x] pthread-compatible API - **IMPLEMENTED**
- [x] Thread pool library - **IMPLEMENTED**

**Kernel Threads Implementation Notes:**
- `kernel/process.asm` lines 1045-1600 - Thread functions
- PCB extensions: PCB_IS_THREAD, PCB_MAIN_PROC, PCB_THREAD_ID, PCB_NEXT_TID
- PCB thread join fields: PCB_THREAD_EXIT_STATUS, PCB_THREAD_JOINED, PCB_THREAD_JOINER, PCB_THREAD_DETACHED
- Threads share address space (same page directory) with parent process
- Each thread has independent 4KB kernel stack
- Syscalls 200-206: thread_create, thread_exit, thread_yield, get_thread_id, is_thread, thread_join, thread_detach
- `lib/syscalls.bh` - Userland thread API (thread_create, thread_exit, thread_yield, thread_join, thread_detach)
- `lib/pthread.bh` - POSIX pthread-compatible API (pthread_create, pthread_join, pthread_exit, pthread_self, pthread_equal, pthread_detach)

**Thread-Local Storage Implementation Notes:**
- PCB field: PCB_TLS_BASE (offset 128) - Per-thread TLS pointer
- Syscalls 220-221: set_tls, get_tls
- `lib/tls.bh` - TLS library with key-value API
- Up to 32 TLS keys per process
- Static TLS allocation for up to 16 threads
- errno-style TLS example included

**Thread Pool Implementation Notes:**
- `lib/threadpool.bh` - Thread pool library for parallel task execution
- Up to 16 worker threads, 64 pending tasks
- Functions: threadpool_init, threadpool_submit, threadpool_wait, threadpool_shutdown
- Task queue with mutex protection
- Semaphore signaling for work availability
- Supports parallel map operations

### 4.3 Resource Limits
- [ ] Per-process memory limits
- [ ] CPU time limits
- [ ] Open file limits
- [ ] Process count limits
- [ ] cgroups-style hierarchical limits

### 4.4 Users & Permissions
- [ ] Multi-user support (uid/gid)
- [ ] File permission enforcement
- [ ] setuid/setgid executables
- [ ] Capability system (fine-grained privileges)
- [ ] Access Control Lists (ACLs)

---

## Phase 5: Security Hardening

### 5.1 Address Space Protection
- [ ] ASLR (randomize stack, heap, mmap, executable)
- [ ] PIE (Position Independent Executables)
- [ ] NX bit (non-executable data pages)
- [ ] Stack canaries in compiler
- [ ] Guard pages around stacks
- [ ] KASLR (kernel address randomization)

### 5.2 Privilege Separation
- [ ] Proper ring 0/ring 3 enforcement
- [ ] Syscall argument validation
- [ ] SMAP/SMEP (prevent kernel access to user memory)
- [ ] Seccomp-style syscall filtering
- [ ] Sandboxing framework

### 5.3 Exploit Mitigations
- [ ] Control Flow Integrity (CFI)
- [ ] Shadow stacks (if hardware supports)
- [ ] Heap hardening (randomization, guards)
- [ ] Integer overflow checking (optional)

---

## Phase 6: Filesystem & Storage

### 6.1 Filesystem Maturity - BrainFS ✓ IMPLEMENTED
- [x] BrainFS ext2-style filesystem - **Full implementation in kernel_main.bh**
- [x] mkfs, mount, umount operations
- [x] Inode and block bitmap allocation
- [x] Directory operations (create, list, lookup, delete)
- [x] File read/write with block allocation
- [x] Auto-mount at boot (formats if needed)
- [ ] Journaling (crash consistency)
- [ ] fsck / recovery tools
- [x] File locking (flock, fcntl) - **IMPLEMENTED: flock() syscall with LOCK_SH, LOCK_EX, LOCK_UN, LOCK_NB**
- [ ] Extended attributes
- [x] Symbolic links - **IMPLEMENTED: brfs_symlink/brfs_readlink + sys_symlink/sys_readlink syscalls**
- [x] Hard links - **IMPLEMENTED: brfs_link/brfs_unlink + sys_link/sys_unlink syscalls**
- [ ] Quotas

**Implementation Notes:**
- Magic: 0x42524653 ("BRFS"), 1KB blocks, 32-byte inodes
- Supports 4 simultaneous mount points
- Boot disk (device 0) protected from formatting
- kernel/kernel_main.bh lines 1143-2240 (includes symlink and hard link support)
- Symlink type: BRFS_S_IFLNK (0xA000), directory entry type 3
- Max symlink depth: 8 levels (loop detection)
- Syscalls 88-89: symlink(), readlink()
- Hard links: Syscalls 9 (SYS_LINK) and 10 (SYS_UNLINK)
- File locking: kernel/flock_impl.bh - 64 concurrent locks, per-FD tracking, auto-release on close/exit
- flock() syscall 82: LOCK_SH (shared/read), LOCK_EX (exclusive/write), LOCK_UN (unlock), LOCK_NB (non-blocking)
- Hard link implementation: nlinks field in inode (offset 2), incremented on link(), decremented on unlink()
- Inode freed only when nlinks reaches 0, prevents hard links to directories (POSIX)
- Shell commands: dsymlink, dreadlink, dls shows symlinks with ->
- kernel/isr.asm lines 521-525, 947-967 (hard link syscalls)

### 6.2 Block Layer ✓ COMPLETE
- [x] Unified block device interface - **blkdev_register/read/write**
- [x] Partition table support (MBR) - **partition_scan_all()**
- [x] LBA translation for partitions
- [x] Support for up to 16 block devices
- [ ] GPT partition support
- [ ] Software RAID (optional)
- [ ] LVM-style volume management (optional)

### 6.3 Drivers - ATA ✓ COMPLETE
- [x] ATA/IDE PIO mode driver - **kernel/ata.bh, kernel/ata.asm**
- [x] Drive detection via IDENTIFY
- [x] 4-drive support (primary/secondary, master/slave)
- [ ] AHCI/SATA driver
- [ ] NVMe driver
- [ ] Virtio-blk (for VMs)
- [ ] USB mass storage

### 6.4 Additional Filesystems ✓ TMPFS IMPLEMENTED
- [ ] FAT32 (USB drives, compatibility)
- [ ] ISO9660 (CD-ROMs)
- [x] tmpfs (memory-backed) - **Fully implemented**
- [ ] Network filesystem (NFS or custom)

**Tmpfs Implementation Notes:**
- `kernel/kernel_main.bh` lines 2078-2324 - Full tmpfs implementation
- Memory-only filesystem with up to 64 inodes
- Operations: mkfs, unmount, create, lookup, read, write, unlink, readdir
- 64KB max file size, 32 character max filenames
- Data stored at fixed memory locations (0x800000+)
- Shell commands available: tmount, tumount, tls, ttouch, tmkdir, twrite, tcat, trm
- Perfect for /tmp, build directories, and testing
- Files disappear on unmount/reboot as expected

---

## Phase 7: Networking Maturity

### 7.0 Core Networking ✓ IMPLEMENTED
- [x] E1000 network driver (Intel 82540EM/82545EM/82574L)
- [x] Ethernet frame handling
- [x] ARP cache and address resolution (16 entries)
- [x] IPv4 packet construction and parsing
- [x] ICMP echo (ping) support
- [x] UDP send/receive (for DHCP, DNS)
- [x] DHCP client (auto IP configuration)
- [x] TCP stack with 11 states (16 concurrent connections)
- [x] TCP three-way handshake and FIN teardown
- [x] Socket API (9 syscalls: listen, accept, connect, send, recv, close, state, poll, has_data)
- [x] HTTP/1.0 client and server library
- [x] Flask-style web framework (32 routes, query/POST/cookie parsing)
- [x] Blocking and non-blocking I/O helpers

**Implementation Notes:**
- `lib/net.bh` - Userland socket API (257 lines)
- `lib/http.bh` - HTTP client/server (216 lines)
- `lib/flask.bh` - Flask-style framework (1501 lines)
- `kernel/kernel_main.bh` lines 7256-10904 - TCP/IP stack
- `kernel/net.asm` - PCI/port I/O helpers (327 lines)
- Known issues: E1000 RX ring init TODO, polling-only (no IRQ)

### 7.1 Protocol Completeness
- [x] DNS resolver - **IMPLEMENTED**
- [ ] IPv6 support
- [x] Unix domain sockets - **IMPLEMENTED**
- [ ] Raw sockets
- [ ] Multicast support

**Unix Domain Socket Implementation Notes:**
- `kernel/kernel_main.bh` lines 3131-3387 - Unix socket functions
- 8 concurrent Unix sockets supported
- Path-based addressing (max 64 chars)
- Syscalls 210-216: unix_listen, unix_connect, unix_accept, unix_send, unix_recv, unix_close, unix_has_data
- `lib/syscalls.bh` - Userland Unix socket API
- Connection states: CLOSED, LISTENING, CONNECTING, CONNECTED
- 1KB buffer per socket for receive data

**DNS Resolver Implementation Notes:**
- `lib/dns.bh` - Full DNS client library (315 lines)
- RFC 1035 compliant DNS query/response handling
- A record (IPv4) lookups with proper packet parsing
- DNS name compression support (0xC0 pointers)
- 8.8.8.8 default DNS server (configurable via dns_set_server)
- Automatic retry with timeout (3 retries, 5 second timeout)
- Transaction ID tracking for response validation
- RCODE error checking (format error, server failure, name error)
- `userland/nslookup.bh` - DNS lookup utility
- Requires UDP syscalls: SYS_UDP_SEND (58), SYS_UDP_RECV (59)

**HTTP Library Enhancements:**
- `lib/http.bh` - Enhanced HTTP client/server library (650+ lines)
- HTTP status code parsing
- Header extraction (case-insensitive)
- Content-Length and Location header parsing
- HTTP POST request support
- Full response GET (headers + body)
- URL parsing (host, port, path extraction)
- Query string parameter parsing
- URL encoding/decoding
- `userland/wget.bh` - wget-like file downloader utility

### 7.2 Performance & Reliability
- [ ] TCP congestion control (Reno/CUBIC)
- [ ] TCP window scaling
- [ ] Connection timeouts & cleanup
- [ ] Socket buffer tuning
- [ ] Zero-copy I/O (sendfile, splice)

### 7.3 Security
- [ ] TLS/SSL library (see Phase 8)
- [ ] Firewall / packet filtering
- [ ] Rate limiting

### 7.4 Additional Drivers
- [ ] Virtio-net (VMs)
- [ ] RTL8139 (common legacy NIC)
- [ ] USB Ethernet adapters

---

## Phase 8: Cryptography & TLS

### 8.1 Crypto Primitives ✓ COMPLETE (RNG, AES, SHA-256/512, ChaCha20, Poly1305, X25519, Ed25519)
- [x] AES (with hardware acceleration) - **Fully implemented**
- [x] ChaCha20 - **Fully implemented**
- [x] Poly1305 (for ChaCha20-Poly1305 AEAD) - **Fully implemented**
- [x] SHA-2 family (256, 384, 512) - **SHA-256 + SHA-512 fully implemented**

**Poly1305 Implementation Notes:**
- `kernel/poly1305.asm` - Full Poly1305 MAC implementation (RFC 8439)
- `lib/poly1305.bh` - Userland Poly1305 library
- `lib/aead.bh` - ChaCha20-Poly1305 AEAD construction
- 130-bit arithmetic using 5 x 26-bit limbs
- Poly1305 key generation from ChaCha20 (counter=0)
- aead_encrypt/aead_decrypt with authenticated encryption
- Constant-time tag comparison for security

**ChaCha20 Implementation Notes:**
- `kernel/chacha20.asm` - Full ChaCha20 stream cipher (RFC 8439)
- `lib/chacha20.bh` - Userland ChaCha20 library
- 256-bit key, 96-bit nonce, 32-bit counter
- 64-byte keystream blocks
- Functions: chacha20_init, chacha20_block, chacha20_encrypt
- Quarter round and double round operations per RFC
- Suitable for TLS 1.3 and general-purpose encryption

- [ ] SHA-3 (optional)
- [ ] RSA
- [x] X25519 key exchange - **Fully implemented**
- [x] Ed25519 signatures - **Fully implemented**
- [x] Secure RNG (RDRAND + entropy pool) - **Fully implemented**

**RNG Implementation Notes:**
- `kernel/rng.asm` - Hardware RNG with RDRAND detection
- `lib/random.bh` - Userland random number library
- Syscall 80 (SYS_GETRANDOM) - Kernel random bytes interface
- RDRAND support with automatic fallback to entropy pool
- Entropy sources: TSC, timer ticks, stack addresses, keyboard timing
- Provides: random_int(), random_range(), random_bytes(), random_uuid(), etc.
- Test program: `userland/random_test.bh`

**X25519 Implementation Notes:**
- `kernel/x25519.asm` - Full X25519 key exchange (RFC 7748)
- `lib/x25519.bh` - Userland X25519 library with high-level API
- Elliptic curve Diffie-Hellman on Curve25519
- Prime: p = 2^255 - 19, Montgomery ladder for scalar multiplication
- Field elements: 10 x 26-bit limbs for efficient arithmetic
- Syscalls 240-241: x25519_keygen, x25519_shared
- Functions: x25519_keypair, x25519_compute_shared, x25519_init_exchange, x25519_finalize_exchange
- Key derivation helpers for TLS integration
- Constant-time key comparison for security
- Ready for TLS 1.3 key exchange

**AES Implementation Notes:**
- `kernel/aes.asm` - Full AES implementation with AES-NI hardware acceleration
- `lib/aes.bh` - Userland AES library with high-level API
- Supports AES-128, AES-192, and AES-256 key sizes
- ECB mode (single block) and CBC mode (practical encryption)
- Hardware detection via CPUID (AES-NI bit 25 in ECX)
- Automatic fallback to software implementation if no AES-NI
- Complete S-box and inverse S-box tables
- PKCS#7 padding support for arbitrary length data
- High-level string encryption/decryption functions
- Functions: aes_init(), aes_set_key(), aes_encrypt_block(), aes_decrypt_block(), aes_cbc_encrypt(), aes_cbc_decrypt()

**SHA-256 Implementation Notes:**
- `kernel/sha256.asm` - Full SHA-256 implementation following FIPS 180-4 specification
- `lib/sha256.bh` - Userland library with HMAC-SHA256 and PBKDF2 support
- Core functions: sha256_init(), sha256_update(), sha256_final(), sha256_hash()
- Supports incremental hashing (streaming API) and one-shot hashing
- 32-byte (256-bit) digest output with proper padding
- Additional utilities: sha256_to_hex(), sha256_compare()
- HMAC-SHA256 for message authentication (RFC 2104)
- PBKDF2 password-based key derivation (simplified single-block version)
- Handles arbitrary length messages with correct bit-length encoding
- All test vectors verified against FIPS 180-4 examples

**SHA-512 Implementation Notes:**
- `kernel/sha512.asm` - Full SHA-512 implementation following FIPS 180-4 specification
- 64-bit arithmetic emulated on 32-bit x86 using register pairs
- Core functions: sha512_init(), sha512_update(), sha512_final(), sha512_hash()
- 128-byte (1024-bit) block size, 64-byte (512-bit) digest output
- 80 rounds with 64-bit round constants and operations
- Syscalls 260-262: sha512_init, sha512_update, sha512_final
- Required for Ed25519 signature scheme
- Streaming API for large messages

**Ed25519 Implementation Notes:**
- `kernel/ed25519.asm` - Full Ed25519 digital signature implementation
- `lib/ed25519.bh` - Userland Ed25519 library with high-level API
- EdDSA signature scheme using twisted Edwards curve
- 32-byte public keys, 64-byte private keys (seed || pubkey), 64-byte signatures
- Uses SHA-512 for key derivation and signature computation
- Deterministic signatures (no random nonce required)
- Syscalls 270-272: ed25519_keygen, ed25519_sign, ed25519_verify
- Functions: ed25519_generate_keypair(), ed25519_sign(), ed25519_verify()
- ~128-bit security level
- Fast verification, suitable for certificate validation
- Required for TLS 1.3 certificate verification

**Crypto Libraries Implementation Notes:**
- `lib/base64.bh` - Base64/URL-safe Base64/PEM/Hex encoding (400+ lines)
- `lib/hmac.bh` - HMAC-SHA256/SHA512, HKDF, PBKDF2 (500+ lines)
- `lib/crypto.bh` - Unified high-level crypto API (600+ lines)
- Base64 encode/decode with proper padding handling
- URL-safe variant (- and _ instead of + and /)
- PEM format encoding/decoding for certificates
- HMAC with streaming and one-shot APIs
- HKDF key derivation (RFC 5869) for SHA-256 and SHA-512
- PBKDF2 password-based key derivation (RFC 8018)
- Unified API: crypto_sha256(), crypto_hmac_sha256(), crypto_aead_encrypt(), etc.
- Constant-time comparison functions for security

### 8.2 TLS Stack ✓ TLS 1.3 FOUNDATION IMPLEMENTED
- [x] TLS 1.3 handshake (ClientHello, ServerHello, Finished) - **Foundation implemented**
- [ ] TLS 1.2 (compatibility)
- [ ] Certificate parsing (X.509)
- [ ] Certificate validation
- [x] SNI support - **Basic implementation**
- [ ] Session resumption

**TLS 1.3 Implementation Notes:**
- `lib/tls13.bh` - Complete TLS 1.3 client library (1100+ lines)
- RFC 8446 compliant handshake using ChaCha20-Poly1305-SHA256 cipher suite
- HKDF key derivation (HKDF-Extract, HKDF-Expand, HKDF-Expand-Label)
- Key schedule: early secret, handshake secret, traffic keys
- Record layer encryption/decryption with proper nonce derivation
- ClientHello builder with extensions (supported_versions, supported_groups, key_share)
- ServerHello parser with key share extraction
- Finished message construction and verification
- High-level API: tls_connect_full(), tls_https_get()
- Functions: tls_init, tls_connect, tls_send, tls_recv, tls_close
- Uses: X25519 (key exchange), ChaCha20-Poly1305 (AEAD), SHA-256 (transcript hash)
- TODO: X.509 certificate parsing, certificate chain validation

### 8.3 Applications ✓ HTTPS FOUNDATION
- [x] HTTPS in Flask library - **Foundation implemented**
- [ ] SSH server/client (ambitious but cool)

**HTTPS/X.509 Implementation Notes:**
- `lib/x509.bh` - X.509 certificate parsing library (650+ lines)
- ASN.1 DER decoder for certificate structures
- Certificate fields: version, serial, issuer, subject, validity, public key
- Extension parsing: basicConstraints (CA detection)
- Public key extraction: Ed25519, X25519, RSA, ECDSA
- Validation helpers: x509_verify_signature, x509_check_validity, x509_check_hostname
- `lib/flask.bh` - HTTPS server support added
- Functions: configure_https(), run_https(), is_https_enabled()
- TODO: Full TLS 1.3 server handshake implementation
- [ ] Encrypted filesystem (optional)

---

## Phase 9: Graphics & Desktop

### 9.1 Display Infrastructure ✓ IMPLEMENTED
- [x] VTNext graphics protocol - **ESC sequences over serial**
- [x] Framebuffer support via multiboot
- [x] 1024x768 resolution
- [ ] Mode setting (resolution switching)
- [ ] Multiple display support
- [ ] Hardware acceleration (basic 2D)

**Implementation Notes:**
- tools/vtnext_terminal.py - Python/pygame renderer
- Kernel sends VTNext commands via serial
- Supports: clear, rect, circle, text, flip

### 9.2 VTNext Enhancements ✓ PARTIALLY IMPLEMENTED
- [x] Basic font rendering - **Built-in font in pygame terminal**
- [x] Graphics primitives (rect, circle, text)
- [ ] Anti-aliasing
- [ ] Image loading (PNG, BMP)
- [ ] Clipboard support
- [ ] Drag and drop

### 9.3 Desktop Environment ✓ IMPLEMENTED
- [x] Desktop with taskbar - **desktop_draw_taskbar()**
- [x] Apps menu popup - **desktop_draw_apps_menu()**
- [x] Desktop icons - **desktop_draw_icons()**
- [x] Clock display - **desktop_draw_clock()**
- [x] Window drawing - **desktop_draw_window()**
- [x] Mouse cursor tracking - **handle_mouse_move/down/up()**
- [ ] Window manager improvements (tiling option)
- [ ] System settings app
- [ ] Notifications

### 9.4 Input ✓ IMPLEMENTED
- [x] Mouse tracking via VTNext protocol
- [x] Mouse click handling
- [x] Keyboard input
- [ ] USB HID support
- [ ] Multi-keyboard/mouse
- [ ] Touchpad gestures (optional)

---

## Phase 10: Self-Hosting & Language

### 10.1 Self-Hosted Compiler
- [ ] Rewrite lexer in Brainhair
- [ ] Rewrite parser in Brainhair
- [ ] Rewrite type checker in Brainhair
- [ ] Rewrite x86_64 codegen in Brainhair
- [ ] Bootstrap: compiler compiles itself
- [ ] Eliminate Python dependency

### 10.2 Language Features
- [ ] Generics / parametric polymorphism
- [ ] Sum types (enums with data)
- [ ] Pattern matching
- [ ] Result/Option types for error handling
- [ ] Async/await (with runtime)
- [ ] Closures / lambdas
- [ ] Modules / namespaces
- [ ] Traits / interfaces

### 10.3 Standard Library
- [ ] Collections (HashMap, Vec, Set)
- [ ] String builder
- [ ] Regex
- [x] Date/time - **IMPLEMENTED: lib/time.bh with RTC syscalls**
- [x] Serialization (JSON) - **IMPLEMENTED: lib/json.bh (18KB)**
- [x] Base64/Hex encoding - **IMPLEMENTED: lib/base64.bh**
- [x] Cryptography utilities - **IMPLEMENTED: lib/crypto.bh, lib/hmac.bh**
- [ ] Serialization (binary)
- [ ] Comprehensive I/O

**Implementation Notes:**
- `lib/time.bh` - Time formatting, Unix timestamp conversion, day-of-week calculation
- `kernel/rtc.asm` - CMOS RTC driver with syscalls 80-81
- `lib/json.bh` - JSON parsing and generation library
- `userland/date.bh` - Date command using RTC
- `lib/base64.bh` - Base64, URL-safe Base64, PEM, Hex encoding/decoding
- `lib/hmac.bh` - HMAC-SHA256/512, HKDF, PBKDF2 key derivation
- `lib/crypto.bh` - Unified crypto API (hash, HMAC, AEAD, signatures, key exchange)

### 10.4 Tooling
- [ ] Debugger (GDB-like)
- [ ] Profiler
- [ ] Memory sanitizer
- [ ] Fuzzer
- [ ] Package manager
- [ ] Documentation generator

---

## Phase 11: Hardware Support

### 11.1 Bus & Device Detection
- [ ] Full PCI/PCIe enumeration
- [ ] USB stack (UHCI/OHCI/EHCI/xHCI)
- [ ] ACPI power management
- [ ] Device hotplug

### 11.2 Common Hardware
- [ ] Sound (basic audio output)
- [ ] Real-time clock improvements
- [ ] CMOS/NVRAM
- [ ] Temperature sensors (optional)

### 11.3 Platform Support
- [ ] UEFI boot (alongside BIOS)
- [ ] ARM64 port (ambitious, long-term)
- [ ] RISC-V port (future-looking)

---

## Suggested Priority Order

For a well-rounded general-purpose OS:

| Priority | Phase | Rationale |
|----------|-------|-----------|
| 1 | 64-bit (1) | Foundation for everything else |
| 2 | Process/Threads (4.1-4.2) | Multi-tasking basics |
| 3 | SMP (3) | Modern CPUs are multi-core |
| 4 | GC (2) | Developer productivity |
| 5 | Security (5) | Can't ignore in 2025 |
| 6 | Filesystem (6.1) | Data integrity |
| 7 | Self-hosting (10.1) | Independence from Python |
| 8 | Language features (10.2) | Expressiveness |
| 9 | Everything else | Build out as needed |

---

## Success Criteria

BrainhairOS is a "mature OS" when it can:

- [ ] Run on real 64-bit hardware (not just QEMU)
- [ ] Compile itself (self-hosting)
- [ ] Run multiple applications simultaneously without crashes
- [ ] Support multiple users with proper isolation
- [ ] Survive a week of uptime under load
- [ ] Have a usable desktop environment
- [ ] Not leak memory (GC works correctly)
- [ ] Boot in under 10 seconds
- [ ] Have comprehensive documentation

---

## The Unique Vision

While building "yet another OS," preserve what makes BrainhairOS special:

1. **Typed Binary Pipelines** - Keep the PSCH format, expand it
2. **Brainhair Language** - Make it as nice as Rust/Go to use
3. **Minimalism** - Don't become bloated, stay lean
4. **Hackability** - Easy to understand and modify
5. **Self-Contained** - Minimal external dependencies

The goal: An OS you'd actually *want* to use, not just one that technically works.
