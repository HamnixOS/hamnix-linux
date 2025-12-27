# SHA-256 Implementation for BrainhairOS

## Overview

This document describes the SHA-256 (Secure Hash Algorithm 256-bit) implementation for BrainhairOS, following the FIPS 180-4 specification.

## Files

### Kernel Implementation
- **`kernel/sha256.asm`** - Low-level x86 assembly implementation (695 lines)
  - Core SHA-256 algorithm in optimized assembly
  - Functions: `sha256_init`, `sha256_update`, `sha256_final`, `sha256_hash`
  - Internal function: `sha256_transform` (processes 512-bit blocks)

### Userland Library
- **`lib/sha256.bh`** - High-level Brainhair wrapper library (344 lines)
  - Easy-to-use API for hashing operations
  - HMAC-SHA256 implementation (RFC 2104)
  - PBKDF2 password-based key derivation (simplified)
  - Utility functions for hex conversion and comparison

### Test Program
- **`userland/sha256_test.bh`** - Comprehensive test suite
  - Validates implementation against known test vectors
  - Tests incremental hashing, HMAC, and PBKDF2

## Architecture

### SHA-256 Context Structure

The SHA-256 context is 108 bytes and has the following layout:

```
Offset | Size | Field       | Description
-------|------|-------------|----------------------------------
0      | 32   | h[8]        | Hash state (8 x 32-bit words)
32     | 64   | data[64]    | Message block buffer
96     | 4    | datalen     | Current data length in buffer
100    | 4    | bitlen_lo   | Total bits processed (low 32)
104    | 4    | bitlen_hi   | Total bits processed (high 32)
```

### Algorithm Overview

SHA-256 processes messages in 512-bit (64-byte) blocks through the following stages:

1. **Initialization** - Set initial hash values (H0-H7)
2. **Message Padding** - Append '1' bit, zeros, and 64-bit length
3. **Message Schedule** - Expand 512-bit block to 64 x 32-bit words
4. **Compression** - 64 rounds of mixing using SHA-256 functions
5. **Finalization** - Convert internal state to 256-bit digest

### Core Functions

#### `sha256_init(ctx: ptr uint8): int32`
Initialize a SHA-256 context with the standard initial hash values (fractional parts of square roots of first 8 primes).

**Returns:** 0 on success, -1 on error

#### `sha256_update(ctx: ptr uint8, data: ptr uint8, len: int32): int32`
Add data to the hash context. Can be called multiple times for incremental hashing.

**Parameters:**
- `ctx` - Pointer to SHA-256 context
- `data` - Pointer to data to hash
- `len` - Length of data in bytes

**Returns:** 0 on success, -1 on error

#### `sha256_final(ctx: ptr uint8, output: ptr uint8): int32`
Finalize the hash and produce the 32-byte digest.

**Parameters:**
- `ctx` - Pointer to SHA-256 context
- `output` - Pointer to 32-byte output buffer

**Returns:** 0 on success, -1 on error

#### `sha256_hash(data: ptr uint8, len: int32, output: ptr uint8): int32`
One-shot hash function that combines init, update, and final.

**Parameters:**
- `data` - Pointer to data to hash
- `len` - Length of data in bytes
- `output` - Pointer to 32-byte output buffer

**Returns:** 0 on success, -1 on error

## Usage Examples

### Example 1: One-Shot Hashing

```brainhair
var data: ptr uint8 = cast[ptr uint8]("Hello, World!")
var hash: array[32, uint8]
sha256_hash_bytes(data, 13, addr(hash[0]))
```

### Example 2: Incremental Hashing

```brainhair
var ctx: SHA256
sha256_init_ctx(addr(ctx))
sha256_update_ctx(addr(ctx), cast[ptr uint8]("Hello, "), 7)
sha256_update_ctx(addr(ctx), cast[ptr uint8]("World!"), 6)
var hash: array[32, uint8]
sha256_final_ctx(addr(ctx), addr(hash[0]))
```

### Example 3: Convert to Hex String

```brainhair
var hash: array[32, uint8]
var hex: array[65, uint8]
sha256_hash_string(cast[ptr uint8]("test"), addr(hash[0]))
sha256_to_hex(addr(hash[0]), addr(hex[0]))
# hex now contains "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
```

### Example 4: HMAC-SHA256

```brainhair
var key: ptr uint8 = cast[ptr uint8]("secret")
var data: ptr uint8 = cast[ptr uint8]("message")
var hmac: array[32, uint8]
sha256_hmac(key, 6, data, 7, addr(hmac[0]))
```

### Example 5: PBKDF2 (Password-Based Key Derivation)

```brainhair
var password: ptr uint8 = cast[ptr uint8]("mypassword")
var salt: ptr uint8 = cast[ptr uint8]("saltvalue")
var key: array[32, uint8]
sha256_pbkdf2(password, 10, salt, 9, 10000, addr(key[0]), 32)
```

## Test Vectors

The implementation has been validated against the following FIPS 180-4 test vectors:

### Test 1: Empty String
```
Input:    ""
Expected: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

### Test 2: "abc"
```
Input:    "abc"
Expected: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
```

### Test 3: Long Message
```
Input:    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
Expected: 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
```

## HMAC-SHA256

HMAC (Hash-based Message Authentication Code) provides message authentication using SHA-256 as the underlying hash function.

**Algorithm (RFC 2104):**
```
HMAC(K, m) = H((K' ⊕ opad) || H((K' ⊕ ipad) || m))
```

Where:
- `K'` is the key padded/hashed to block size (64 bytes)
- `ipad` is 64 bytes of 0x36
- `opad` is 64 bytes of 0x5c
- `||` denotes concatenation

## PBKDF2

Password-Based Key Derivation Function 2 (PBKDF2) derives cryptographic keys from passwords.

**Current Implementation:**
- Single block output (32 bytes maximum)
- Configurable iteration count (recommended: ≥ 10,000)
- Uses HMAC-SHA256 as the pseudorandom function

**Algorithm:**
```
U1 = HMAC(password, salt || block_number)
U2 = HMAC(password, U1)
...
Ui = HMAC(password, U(i-1))

Result = U1 ⊕ U2 ⊕ ... ⊕ Ui
```

## Performance Considerations

### Software Implementation
- All arithmetic operations are 32-bit
- Uses standard x86 rotate and shift instructions
- Stack-based context and working variables
- Approximately 64 rounds per 512-bit block

### Memory Usage
- Context: 108 bytes
- Stack usage in `sha256_transform`: ~320 bytes (for message schedule and working variables)

### Optimization Opportunities
1. **Hardware Acceleration** - Intel SHA extensions (SHA256MSG1, SHA256MSG2, SHA256RNDS2)
2. **SIMD** - Process multiple blocks in parallel
3. **Unrolled Loops** - Reduce loop overhead in compression function

## Security Notes

1. **Collision Resistance** - No practical collisions found for SHA-256
2. **Preimage Resistance** - Computationally infeasible to find input from hash
3. **Second Preimage Resistance** - Hard to find different input with same hash

**Recommended Uses:**
- Digital signatures
- Password hashing (with PBKDF2)
- Message integrity verification
- Cryptographic key derivation
- Blockchain and cryptocurrency

**NOT Recommended:**
- Direct password storage (use PBKDF2 with high iteration count)
- As a source of randomness without additional entropy

## Integration with BrainhairOS

### Build System
- Added to `Makefile` as `SHA256_OBJ`
- Linked into kernel binary
- Available to all userland programs via `lib/sha256.bh`

### No Syscall Required
Unlike some kernel features, SHA-256 is implemented as a pure library that can be linked directly into userland programs. No syscall overhead.

### Future Enhancements
1. Add SHA-384 and SHA-512 support
2. Implement hardware acceleration detection and usage
3. Add streaming API for large files
4. Integrate with TLS stack for secure communications

## References

1. **FIPS 180-4** - Secure Hash Standard (SHS)
   - https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf

2. **RFC 2104** - HMAC: Keyed-Hashing for Message Authentication
   - https://tools.ietf.org/html/rfc2104

3. **RFC 2898** - PKCS #5: Password-Based Cryptography Specification Version 2.0
   - https://tools.ietf.org/html/rfc2898

## Testing

Run the test suite:
```bash
# Compile the test program
./bin/bhbuild userland/sha256_test.bh bin/sha256_test

# Run in BrainhairOS
# (Load and execute bin/sha256_test)
```

Expected output:
```
=== SHA-256 Test Suite ===

Test 1: SHA-256("")
Result:   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
Expected: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

Test 2: SHA-256("abc")
Result:   ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
Expected: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad

[... additional tests ...]

=== All tests complete! ===
```

## License

This implementation is part of BrainhairOS and follows the project's license.

## Author

Implementation completed as part of BrainhairOS Phase 8: Cryptography & TLS
