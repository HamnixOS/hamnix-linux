# ChaCha20-Poly1305 AEAD Implementation for BrainhairOS

This document describes the implementation of the ChaCha20-Poly1305 Authenticated Encryption with Associated Data (AEAD) cipher suite in BrainhairOS.

## Overview

ChaCha20-Poly1305 is a modern, fast, and secure AEAD cipher that combines:
- **ChaCha20**: A stream cipher for confidentiality (encryption)
- **Poly1305**: A MAC (Message Authentication Code) for authenticity and integrity

This implementation follows **RFC 8439** (ChaCha20 and Poly1305 for IETF Protocols).

## Components

### 1. Poly1305 MAC (`kernel/poly1305.asm`)

Assembly implementation of the Poly1305 message authentication code.

**Key Features:**
- Uses 130-bit modular arithmetic (mod 2^130 - 5)
- Processes messages in 16-byte blocks
- Produces 128-bit (16-byte) authentication tags
- Constant-time verification to prevent timing attacks

**Functions:**
```asm
poly1305_init(key: ptr uint8): int32
  - Initialize Poly1305 state with 32-byte key (r||s)
  - Clamps r according to RFC 8439
  - Returns 0 on success, -1 on error

poly1305_update(msg: ptr uint8, len: int32)
  - Process message data incrementally
  - Can be called multiple times

poly1305_final(tag: ptr uint8): int32
  - Finalize computation and output 16-byte tag
  - Returns 0 on success, -1 on error

poly1305_auth(tag: ptr uint8, msg: ptr uint8, len: int32, key: ptr uint8): int32
  - One-shot MAC computation
  - Convenience wrapper for init->update->final
  - Returns 0 on success, -1 on error
```

**Implementation Details:**
- Uses 5 x 26-bit limbs for 130-bit arithmetic
- r component is clamped: clear top 4 bits of bytes 3,7,11,15 and bottom 2 bits of bytes 4,8,12
- Accumulator: a = ((a + block) * r) mod (2^130 - 5)
- Final tag: (a + s) mod 2^128

### 2. Poly1305 Library (`lib/poly1305.bh`)

Brainhair userland wrappers for Poly1305.

**Key Functions:**
```brainhair
poly1305_mac(msg: ptr uint8, len: int32, key: ptr uint8, tag: ptr uint8): int32
  - One-shot MAC computation

poly1305_verify(msg: ptr uint8, len: int32, key: ptr uint8, tag: ptr uint8): int32
  - Verify MAC tag (constant-time comparison)
  - Returns 1 if valid, 0 if invalid, -1 on error

poly1305_key_gen(chacha_key: ptr uint8, nonce: ptr uint8, poly_key: ptr uint8): int32
  - Generate Poly1305 key from ChaCha20 (for AEAD)
  - Uses ChaCha20 with counter=0

poly1305_tag_to_hex(tag: ptr uint8, output: ptr uint8)
  - Convert 16-byte tag to 33-byte hex string
```

### 3. ChaCha20 Cipher (Already Implemented)

Stream cipher implementation in `kernel/chacha20.asm` and `lib/chacha20.bh`.

**Key Properties:**
- 256-bit key (32 bytes)
- 96-bit nonce (12 bytes)
- 32-bit block counter
- 64-byte output blocks

### 4. AEAD Library (`lib/aead.bh`)

Complete ChaCha20-Poly1305 AEAD construction per RFC 8439.

**Main Functions:**
```brainhair
aead_chacha20_poly1305_encrypt(
  plaintext: ptr uint8,
  plaintext_len: int32,
  aad: ptr uint8,              # Additional Authenticated Data (optional)
  aad_len: int32,
  key: ptr uint8,              # 32-byte key
  nonce: ptr uint8,            # 12-byte nonce
  ciphertext: ptr uint8,       # Output buffer
  tag: ptr uint8               # 16-byte tag output
): int32
  - Encrypts plaintext and produces authentication tag
  - AAD is authenticated but not encrypted (for headers, metadata)
  - Returns 0 on success, -1 on error

aead_chacha20_poly1305_decrypt(
  ciphertext: ptr uint8,
  ciphertext_len: int32,
  aad: ptr uint8,
  aad_len: int32,
  tag: ptr uint8,              # 16-byte tag to verify
  key: ptr uint8,
  nonce: ptr uint8,
  plaintext: ptr uint8         # Output buffer
): int32
  - Verifies authentication tag then decrypts
  - Returns:
    - 0 on success (tag verified, plaintext decrypted)
    - -2 on authentication failure (DO NOT use plaintext!)
    - -1 on other errors
```

**AEAD Construction (RFC 8439):**
1. Generate Poly1305 key: `poly_key = ChaCha20(key, nonce, counter=0)[0..31]`
2. Encrypt plaintext: `ciphertext = ChaCha20(key, nonce, counter=1) XOR plaintext`
3. Compute MAC over: `AAD || pad16(AAD) || Ciphertext || pad16(Ciphertext) || len(AAD) || len(Ciphertext)`
4. Tag = Poly1305(mac_data, poly_key)

For decryption:
1. Generate Poly1305 key (same as encryption)
2. Compute expected MAC
3. Verify tag matches (constant-time comparison)
4. Only decrypt if verification passes

## Usage Examples

### Example 1: Simple Encryption (No AAD)

```brainhair
var plaintext: ptr uint8 = cast[ptr uint8]("Hello, World!")
var key: array[32, uint8]
var nonce: array[12, uint8]
var ciphertext: array[64, uint8]
var tag: array[16, uint8]

# Initialize key and nonce (from secure random source)
# ... fill key and nonce ...

# Encrypt
var result: int32 = aead_chacha20_poly1305_encrypt(
  plaintext, 13,
  cast[ptr uint8](0), 0,  # No AAD
  addr(key[0]), addr(nonce[0]),
  addr(ciphertext[0]), addr(tag[0])
)

# Send ciphertext and tag to recipient
```

### Example 2: Encryption with AAD

```brainhair
var plaintext: ptr uint8 = cast[ptr uint8]("Secret data")
var aad: ptr uint8 = cast[ptr uint8]("Public header")
var key: array[32, uint8]
var nonce: array[12, uint8]
var ciphertext: array[64, uint8]
var tag: array[16, uint8]

# Encrypt with AAD
aead_chacha20_poly1305_encrypt(
  plaintext, 11,
  aad, 13,
  addr(key[0]), addr(nonce[0]),
  addr(ciphertext[0]), addr(tag[0])
)
```

### Example 3: Decryption and Verification

```brainhair
var ciphertext: array[64, uint8]
var tag: array[16, uint8]
var key: array[32, uint8]
var nonce: array[12, uint8]
var plaintext: array[64, uint8]

# Receive ciphertext and tag
# Share key and nonce with sender

var result: int32 = aead_chacha20_poly1305_decrypt(
  addr(ciphertext[0]), 13,
  cast[ptr uint8](0), 0,  # No AAD
  addr(tag[0]),
  addr(key[0]), addr(nonce[0]),
  addr(plaintext[0])
)

if result == 0:
  # Success - plaintext is valid and authenticated
elif result == -2:
  # CRITICAL: Authentication failed - message tampered!
  # DO NOT use plaintext - it's invalid
else:
  # Other error
```

### Example 4: Poly1305 MAC Only

```brainhair
var msg: ptr uint8 = cast[ptr uint8]("Authenticate me")
var key: array[32, uint8]
var tag: array[16, uint8]

# Compute MAC
poly1305_mac(msg, 15, addr(key[0]), addr(tag[0]))

# Later, verify MAC
var valid: int32 = poly1305_verify(msg, 15, addr(key[0]), addr(tag[0]))
if valid == 1:
  # Message is authentic
```

## Security Considerations

### CRITICAL: Nonce Management

**NEVER reuse a (key, nonce) pair!**

Nonce reuse completely breaks ChaCha20-Poly1305 security:
- Attackers can recover the keystream
- Authentication can be forged
- Confidentiality is lost

**Best Practices:**
- Use a counter that increments for each message
- Use random nonces (96 bits provides good collision resistance)
- Use timestamps (if monotonic and unique)
- **Never** encrypt two different messages with the same (key, nonce)

### Authentication First

**Always verify authentication before processing plaintext!**

The `aead_chacha20_poly1305_decrypt()` function does this automatically:
- Computes expected MAC
- Verifies tag matches (constant-time)
- Only decrypts if verification passes
- Returns -2 if authentication fails

If you implement your own AEAD wrapper:
```brainhair
# GOOD: Verify first
if verify_tag() != 1:
  return ERROR  # Don't decrypt

decrypt()  # Safe to decrypt

# BAD: Decrypt first
decrypt()
if verify_tag() != 1:
  return ERROR  # Too late - you already used unverified data!
```

### Constant-Time Operations

Timing attacks can leak secrets. Our implementation uses:
- Constant-time MAC verification (XOR accumulation)
- No data-dependent branches in crypto loops
- Fixed-time comparisons for tags

### Key Management

- **Never** hardcode keys in source code
- Store keys securely (encrypted at rest)
- Use key derivation for passwords (PBKDF2, Argon2)
- Rotate keys periodically
- Destroy keys when no longer needed (overwrite memory)

### Additional Authenticated Data (AAD)

AAD is authenticated but **not encrypted**:
- Use for packet headers, protocol metadata, public information
- **Never** put confidential data in AAD
- AAD is integrity-protected (tampering detected)
- AAD is not hidden (anyone can read it)

### Message Size Limits

- ChaCha20 counter is 32-bit: max ~256 GB per (key, nonce)
- Practical limit: depends on available memory
- For large files: use multiple messages with different nonces

### Side-Channel Resistance

This implementation aims for basic side-channel resistance:
- Constant-time MAC comparison
- No secret-dependent branches in critical paths
- Fixed iteration counts

For high-security environments, consider:
- Cache-timing attacks (not fully addressed)
- Power analysis (hardware issue)
- Electromagnetic emanation (hardware issue)

## Test Vectors

### RFC 8439 Section 2.5.2 - Poly1305

**Input:**
- Key: `85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b`
- Message: "Cryptographic Forum Research Group"

**Expected Tag:**
`a8061dc1305136c6c22b8baf0c0127a9`

### Running Tests

```bash
# Build the test program
./bin/bhbuild userland/chacha20_poly1305_test.bh bin/chacha20_poly1305_test

# Run on BrainhairOS
./bin/chacha20_poly1305_test
```

Test suite validates:
- Poly1305 RFC 8439 test vectors
- Incremental MAC computation
- ChaCha20 encryption/decryption
- Combined AEAD construction

## Performance Characteristics

### Poly1305
- **Speed**: Very fast (designed for software)
- **Block Size**: 16 bytes
- **State Size**: ~100 bytes
- **Operations**: 130-bit modular arithmetic

### ChaCha20
- **Speed**: ~2-3 cycles/byte on modern CPUs
- **Block Size**: 64 bytes
- **Parallelizable**: Yes (multiple blocks)
- **Operations**: 32-bit additions, XORs, rotations

### ChaCha20-Poly1305 AEAD
- **Overhead**: 16-byte tag per message
- **Latency**: Single pass over data
- **Throughput**: Limited by ChaCha20 speed
- **Comparison**: Faster than AES-GCM on CPUs without AES-NI

## Comparison with Other Ciphers

| Feature | ChaCha20-Poly1305 | AES-128-GCM | AES-256-CBC+HMAC |
|---------|-------------------|-------------|------------------|
| Security | 256-bit | 128-bit | 256-bit |
| Performance (no AES-NI) | Fast | Slow | Medium |
| Performance (with AES-NI) | Fast | Very Fast | Fast |
| AEAD | Yes | Yes | No (needs HMAC) |
| Constant-time | Yes | Depends | Yes (HMAC) |
| Patent Issues | None | None | None |
| Standardization | RFC 8439, TLS 1.3 | NIST | NIST |

**When to Use ChaCha20-Poly1305:**
- Mobile/embedded devices (no AES hardware)
- Software-only implementations
- TLS 1.3 / modern protocols
- When constant-time crypto is critical

**When to Use AES-GCM:**
- Hardware with AES-NI support
- Maximum throughput needed
- Legacy system compatibility

## Integration with BrainhairOS

### Kernel Integration

Poly1305 is implemented in kernel space:
```
kernel/poly1305.asm    - Assembly implementation
kernel/chacha20.asm    - ChaCha20 cipher (already present)
```

Built into kernel binary:
```makefile
POLY1305_OBJ = $(BUILD_DIR)/poly1305.o
CHACHA20_OBJ = $(BUILD_DIR)/chacha20.o
```

### Userland Libraries

```
lib/poly1305.bh        - Poly1305 wrappers
lib/chacha20.bh        - ChaCha20 wrappers
lib/aead.bh            - ChaCha20-Poly1305 AEAD
```

### Syscall Interface

Crypto functions are called directly (no syscalls needed):
- Kernel functions exported to userland
- Link-time resolution
- No context switching overhead

### Future Enhancements

Potential improvements:
- Hardware acceleration (if available)
- Vectorized implementation (SIMD)
- Async/streaming API for large files
- Integration with networking stack (TLS)
- Key storage service
- Random nonce generation helper

## References

### Standards and Specifications
- **RFC 8439**: ChaCha20 and Poly1305 for IETF Protocols
- **RFC 7539**: ChaCha20 and Poly1305 (superseded by RFC 8439)
- **Original Papers**:
  - ChaCha20: Daniel J. Bernstein (2008)
  - Poly1305: Daniel J. Bernstein (2005)

### Security Analysis
- "ChaCha, a variant of Salsa20" - D.J. Bernstein
- "The Poly1305-AES message-authentication code" - D.J. Bernstein
- IETF CFRG analysis and recommendations

### Implementation References
- Reference C implementation: https://cr.yp.to/chacha.html
- libsodium: https://doc.libsodium.org/
- BoringSSL ChaCha20-Poly1305 implementation

## License and Credits

This implementation follows the design from RFC 8439 and original papers by Daniel J. Bernstein.

ChaCha20 and Poly1305 are in the public domain. No patents restrict their use.

Implementation for BrainhairOS by Claude (2025).

## Support and Troubleshooting

### Common Issues

**Issue**: Tag verification fails
- **Cause**: Different AAD or wrong key/nonce
- **Fix**: Ensure sender and receiver use same AAD, key, nonce

**Issue**: Decryption produces garbage
- **Cause**: Authentication was skipped or failed
- **Fix**: Always check return value of decrypt function

**Issue**: Nonce reuse
- **Cause**: Counter not incremented or random collision
- **Fix**: Implement proper nonce management

### Debug Tips

1. **Enable hex output**: Use `print_block()` to view keys, tags, ciphertext
2. **Test with known vectors**: RFC 8439 provides test cases
3. **Verify incrementally**: Test Poly1305 and ChaCha20 separately first
4. **Check buffer sizes**: Ensure output buffers are large enough

### Getting Help

For questions or issues:
1. Check test program: `userland/chacha20_poly1305_test.bh`
2. Review RFC 8439 test vectors
3. Examine kernel implementation: `kernel/poly1305.asm`

---

**Document Version**: 1.0
**Last Updated**: 2025
**Status**: Production Ready
