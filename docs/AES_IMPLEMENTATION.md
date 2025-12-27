# AES Implementation for BrainhairOS

Advanced Encryption Standard (AES) implementation with hardware AES-NI acceleration and software fallback.

## Overview

BrainhairOS includes a complete AES implementation supporting:
- **AES-128** (128-bit keys, 10 rounds)
- **AES-192** (192-bit keys, 12 rounds)
- **AES-256** (256-bit keys, 14 rounds)
- **ECB mode** (Electronic Codebook - for single blocks)
- **CBC mode** (Cipher Block Chaining - recommended for multi-block)
- **Hardware acceleration** via Intel AES-NI instructions
- **Software fallback** when AES-NI is unavailable
- **PKCS#7 padding** for arbitrary length data

## Files

### Kernel Implementation
- **`kernel/aes.asm`** - Core AES implementation in x86 assembly (560+ lines)
  - Hardware detection (CPUID)
  - AES-NI accelerated encrypt/decrypt
  - Software AES fallback
  - S-box and inverse S-box tables
  - Key expansion
  - CBC mode implementation

### Userland Library
- **`lib/aes.bh`** - High-level AES library for applications (450+ lines)
  - Easy-to-use encryption/decryption API
  - PKCS#7 padding utilities
  - String encryption helpers
  - IV generation
  - Error handling

### Test Program
- **`userland/aes_test.bh`** - Comprehensive test suite
  - AES-128 single block test
  - AES-256 single block test
  - CBC mode multi-block test
  - Hardware detection verification

## Hardware Support Detection

The implementation automatically detects AES-NI support at runtime using CPUID:

```asm
; Check CPUID.01H:ECX.AES[bit 25]
mov eax, 1
cpuid
bt ecx, 25              ; Test bit 25 (AES-NI)
```

If AES-NI is available, all encryption/decryption operations use hardware-accelerated instructions:
- `aesenc` - AES encrypt round
- `aesenclast` - AES final encrypt round
- `aesdec` - AES decrypt round
- `aesdeclast` - AES final decrypt round

If not available, the implementation falls back to software-based AES using lookup tables.

## API Reference

### Kernel Functions (Assembly)

#### `aes_init()`
Initialize the AES subsystem and detect hardware support.

#### `aes_set_key(key, key_len)`
Set the encryption/decryption key.
- **key**: Pointer to key bytes
- **key_len**: Key length (16, 24, or 32 bytes)
- **Returns**: 0 on success, -1 on error

#### `aes_encrypt_block(input, output)`
Encrypt a single 16-byte block (ECB mode).
- **input**: Pointer to 16-byte plaintext
- **output**: Pointer to 16-byte ciphertext buffer
- **Returns**: 0 on success, -1 on error

#### `aes_decrypt_block(input, output)`
Decrypt a single 16-byte block (ECB mode).
- **input**: Pointer to 16-byte ciphertext
- **output**: Pointer to 16-byte plaintext buffer
- **Returns**: 0 on success, -1 on error

#### `aes_cbc_encrypt(input, output, length, iv)`
Encrypt data in CBC mode.
- **input**: Pointer to plaintext (must be multiple of 16 bytes)
- **output**: Pointer to ciphertext buffer
- **length**: Length in bytes (must be multiple of 16)
- **iv**: Pointer to 16-byte initialization vector
- **Returns**: 0 on success, -1 on error

#### `aes_cbc_decrypt(input, output, length, iv)`
Decrypt data in CBC mode.
- **input**: Pointer to ciphertext (must be multiple of 16 bytes)
- **output**: Pointer to plaintext buffer
- **length**: Length in bytes (must be multiple of 16)
- **iv**: Pointer to 16-byte initialization vector (same as used for encryption)
- **Returns**: 0 on success, -1 on error

#### `aes_check_aesni()`
Check if AES-NI hardware acceleration is available.
- **Returns**: 1 if available, 0 otherwise

### Userland Library Functions (Brainhair)

#### `aes_initialize() -> int32`
Initialize the AES library. Must be called before using other functions.
- **Returns**: 0 on success, -1 on error

#### `aes_has_hardware_support() -> int32`
Check for AES-NI hardware support.
- **Returns**: 1 if hardware acceleration available, 0 otherwise

#### `aes_key_init(key, key_len) -> int32`
Initialize AES with an encryption key.
- **key**: Pointer to key bytes
- **key_len**: 16 (AES-128), 24 (AES-192), or 32 (AES-256)
- **Returns**: 0 on success, error code on failure

#### `aes_encrypt_ecb(input, output, length) -> int32`
Encrypt data using ECB mode.
- **Warning**: ECB is not secure for most uses. Use CBC mode instead.
- **input**: Plaintext buffer (multiple of 16 bytes)
- **output**: Ciphertext buffer
- **length**: Data length (must be multiple of 16)
- **Returns**: 0 on success, error code on failure

#### `aes_decrypt_ecb(input, output, length) -> int32`
Decrypt data using ECB mode.

#### `aes_encrypt_cbc_mode(input, output, length, iv) -> int32`
Encrypt data using CBC mode (recommended).
- **input**: Plaintext buffer (multiple of 16 bytes)
- **output**: Ciphertext buffer
- **length**: Data length (must be multiple of 16)
- **iv**: 16-byte initialization vector (should be random and unique)
- **Returns**: 0 on success, error code on failure

#### `aes_decrypt_cbc_mode(input, output, length, iv) -> int32`
Decrypt data using CBC mode.

#### `aes_encrypt_string(plaintext, plaintext_len, output, output_size, key, key_len, iv) -> int32`
High-level string encryption with automatic PKCS#7 padding.
- **plaintext**: Input data
- **plaintext_len**: Length of input
- **output**: Output buffer (must be >= plaintext_len + 16)
- **output_size**: Size of output buffer
- **key**: Encryption key
- **key_len**: Key length (16, 24, or 32)
- **iv**: 16-byte buffer for generated IV (will be written)
- **Returns**: Ciphertext length (with padding), or negative on error

#### `aes_decrypt_string(ciphertext, ciphertext_len, output, output_size, key, key_len, iv) -> int32`
High-level string decryption with automatic PKCS#7 unpadding.
- **Returns**: Plaintext length (without padding), or negative on error

#### `aes_pkcs7_pad(data, data_len, buffer_size) -> int32`
Add PKCS#7 padding to buffer.
- **Returns**: New length with padding, or -1 on error

#### `aes_pkcs7_unpad(data, padded_len) -> int32`
Remove PKCS#7 padding from buffer.
- **Returns**: Original data length, or -1 on error

## Usage Examples

### Example 1: Single Block Encryption (ECB)

```brainhair
# Initialize AES
aes_initialize()

# 128-bit key
var key: array[16, uint8]
# ... fill key ...

# 16-byte plaintext
var plaintext: array[16, uint8]
var ciphertext: array[16, uint8]

# Set key
aes_key_init(addr(key), 16)

# Encrypt single block
aes_encrypt_block(addr(plaintext), addr(ciphertext))

# Decrypt single block
var decrypted: array[16, uint8]
aes_decrypt_block(addr(ciphertext), addr(decrypted))
```

### Example 2: Multi-Block CBC Mode

```brainhair
# Initialize
aes_initialize()

# Generate random IV
var iv: array[16, uint8]
aes_generate_iv(addr(iv))

# Set 256-bit key
var key: array[32, uint8]
aes_key_init(addr(key), 32)

# Encrypt 32 bytes (2 blocks)
var plaintext: array[32, uint8]
var ciphertext: array[32, uint8]
aes_encrypt_cbc_mode(addr(plaintext), addr(ciphertext), 32, addr(iv))

# Decrypt
var decrypted: array[32, uint8]
aes_decrypt_cbc_mode(addr(ciphertext), addr(decrypted), 32, addr(iv))
```

### Example 3: String Encryption (High-Level)

```brainhair
# Initialize
aes_initialize()

# Prepare buffers
var plaintext: ptr uint8 = "Hello, BrainhairOS!"
var plaintext_len: int32 = 19
var output: array[64, uint8]  # Must be large enough for padding
var key: array[32, uint8]     # 256-bit key
var iv: array[16, uint8]

# Encrypt (handles padding automatically)
var cipher_len: int32 = aes_encrypt_string(
  plaintext, plaintext_len,
  addr(output), 64,
  addr(key), 32,
  addr(iv)
)

# Decrypt
var decrypted: array[64, uint8]
var plain_len: int32 = aes_decrypt_string(
  addr(output), cipher_len,
  addr(decrypted), 64,
  addr(key), 32,
  addr(iv)
)
```

## Error Codes

```brainhair
const AES_SUCCESS: int32 = 0
const AES_ERROR: int32 = -1
const AES_ERROR_INVALID_KEY: int32 = -2
const AES_ERROR_INVALID_LENGTH: int32 = -3
const AES_ERROR_NULL_POINTER: int32 = -4
```

## Security Considerations

### DO Use
- **CBC mode** for encrypting multiple blocks
- **Random, unique IVs** for each encryption operation
- **Strong keys** from a cryptographically secure RNG
- **Authenticated encryption** (e.g., AES-GCM) for production - coming soon

### DON'T Use
- **ECB mode** for anything except single blocks or testing
- **Hardcoded keys** in production code
- **Reused IVs** with the same key in CBC mode
- **Predictable IVs**

### Best Practices
1. Always use CBC mode (or better) for multi-block encryption
2. Generate IVs using the system RNG (`random_bytes()`)
3. Store IVs alongside ciphertext (they don't need to be secret)
4. Use AES-256 for maximum security (32-byte keys)
5. Implement authentication (HMAC) on top of AES encryption
6. Never roll your own crypto protocol

## Implementation Details

### S-Box Tables
The implementation includes complete S-box and inverse S-box lookup tables for software AES:
- Forward S-box (256 bytes) for encryption
- Inverse S-box (256 bytes) for decryption

### Key Expansion
The key expansion algorithm generates round keys from the cipher key:
- AES-128: 11 round keys (176 bytes)
- AES-192: 13 round keys (208 bytes)
- AES-256: 15 round keys (240 bytes)

### Round Constants
Rcon values are pre-computed for key expansion.

### CBC Implementation
CBC mode XORs each plaintext block with the previous ciphertext block (or IV for the first block):

```
Encryption: C[i] = E(P[i] XOR C[i-1])
Decryption: P[i] = D(C[i]) XOR C[i-1]
```

## Performance

With AES-NI hardware support:
- **Encryption**: ~1-2 CPU cycles per byte
- **Decryption**: ~1-2 CPU cycles per byte

Software fallback (approximate):
- **Encryption**: ~10-20 CPU cycles per byte
- **Decryption**: ~10-20 CPU cycles per byte

## Testing

Run the test program to verify the implementation:

```bash
# Build and run AES tests
./bin/bhbuild userland/aes_test.bh bin/aes_test
./bin/aes_test
```

Expected output:
```
BrainhairOS AES Encryption Test
================================
Hardware AES-NI support: AVAILABLE

=== AES-128 Test ===
Key: ...
Plaintext: ...
Ciphertext: ...
Decrypted: ...
✓ AES-128 test PASSED

=== AES-256 Test ===
...
✓ AES-256 test PASSED

=== CBC Mode Test ===
...
✓ CBC mode test PASSED

================================
All tests completed!
```

## Future Enhancements

Planned additions to the AES implementation:
- [ ] **AES-GCM** mode (Galois/Counter Mode) for authenticated encryption
- [ ] **CTR mode** (Counter mode) for parallelizable encryption
- [ ] **XTS mode** for disk encryption
- [ ] **Key wrapping** (RFC 3394)
- [ ] **AEAD** (Authenticated Encryption with Associated Data)
- [ ] **Optimization** of software fallback implementation
- [ ] **Assembly optimization** for non-AES-NI path
- [ ] **Side-channel resistance** improvements

## References

- FIPS 197: Advanced Encryption Standard (AES)
- Intel AES-NI Programming Guide
- NIST Special Publication 800-38A (Modes of Operation)
- RFC 5652: PKCS#7 Padding

## Integration with BrainhairOS

The AES implementation is fully integrated into the kernel:
- Compiled with `make microkernel`
- Available as kernel functions callable from userland
- Used by networking stack for TLS (future)
- Used by filesystem for encryption (future)
- Available to all userland programs via `lib/aes.bh`

## License

Part of BrainhairOS - Phase 8 Cryptography Foundation
