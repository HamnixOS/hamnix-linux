# AES Encryption - Quick Start Guide

## What is AES?

AES (Advanced Encryption Standard) is the industry-standard symmetric encryption algorithm used worldwide. BrainhairOS provides a complete AES implementation with hardware acceleration.

## Quick Example

```brainhair
# Include AES library
# Uses: lib/aes.bh

# 1. Initialize
aes_initialize()

# 2. Create a key (256-bit = 32 bytes for maximum security)
var key: array[32, uint8]
# Fill with random data from RNG
random_bytes(addr(key), 32)

# 3. Encrypt a message
var message: ptr uint8 = "Secret message!"
var message_len: int32 = 15
var encrypted: array[64, uint8]
var iv: array[16, uint8]

# Set the encryption key
aes_key_init(addr(key), 32)  # 32 = AES-256

# Encrypt (handles padding automatically)
var cipher_len: int32 = aes_encrypt_string(
  message, message_len,
  addr(encrypted), 64,
  addr(key), 32,
  addr(iv)
)

# 4. Decrypt
var decrypted: array[64, uint8]
var plain_len: int32 = aes_decrypt_string(
  addr(encrypted), cipher_len,
  addr(decrypted), 64,
  addr(key), 32,
  addr(iv)
)

# decrypted now contains "Secret message!"
```

## Key Sizes

Choose based on your security needs:

| Key Size | Security Level | Use Case |
|----------|---------------|----------|
| 16 bytes | AES-128 | Fast, good security |
| 24 bytes | AES-192 | Medium, better security |
| 32 bytes | AES-256 | Slower, maximum security |

**Recommendation**: Use AES-256 (32 bytes) for new applications.

## Modes

### ECB (Electronic Codebook)
- ⚠️ **NOT SECURE** for most uses
- Only for single 16-byte blocks
- Same plaintext = same ciphertext (bad!)
- Use `aes_encrypt_block()` / `aes_decrypt_block()`

### CBC (Cipher Block Chaining)
- ✓ **SECURE** for multi-block data
- Requires random IV (Initialization Vector)
- Different ciphertext each time (good!)
- Use `aes_encrypt_cbc_mode()` / `aes_decrypt_cbc_mode()`

**Recommendation**: Always use CBC mode for real encryption.

## Important: Initialization Vectors (IVs)

For CBC mode, you MUST use a random, unique IV:

```brainhair
# Generate random IV
var iv: array[16, uint8]
aes_generate_iv(addr(iv))  # Or use random_bytes()

# Encrypt with IV
aes_encrypt_cbc_mode(plaintext, ciphertext, length, addr(iv))

# Store IV with ciphertext (it's not secret!)
# Later, use same IV to decrypt:
aes_decrypt_cbc_mode(ciphertext, plaintext, length, addr(iv))
```

**Rules:**
- Generate new IV for EACH encryption
- Store IV with the ciphertext (prepend or append)
- IV doesn't need to be secret, just random and unique
- NEVER reuse an IV with the same key

## Hardware Acceleration

BrainhairOS automatically uses Intel AES-NI if available:

```brainhair
if aes_has_hardware_support():
  print("Using hardware acceleration (fast!)")
else:
  print("Using software implementation (slower)")
```

No code changes needed - it's automatic!

## Common Patterns

### Pattern 1: Encrypt File Data

```brainhair
# Read file into buffer
var file_data: ptr uint8 = ...
var file_size: int32 = ...

# Calculate padded size (round up to 16-byte multiple)
var padding: int32 = 16 - (file_size % 16)
if padding == 0:
  padding = 16
var padded_size: int32 = file_size + padding

# Encrypt
var encrypted: ptr uint8 = malloc(padded_size)
var iv: array[16, uint8]
random_bytes(addr(iv), 16)

aes_encrypt_cbc_mode(file_data, encrypted, padded_size, addr(iv))

# Save: IV (16 bytes) + encrypted data
write_file("encrypted.bin", addr(iv), 16)
append_file("encrypted.bin", encrypted, padded_size)
```

### Pattern 2: Secure String Storage

```brainhair
# Encrypt password before storing
var password: ptr uint8 = "MyPassword123"
var key: array[32, uint8]
# Derive key from master password or use fixed key

var encrypted: array[128, uint8]
var iv: array[16, uint8]

var cipher_len: int32 = aes_encrypt_string(
  password, strlen(password),
  addr(encrypted), 128,
  addr(key), 32,
  addr(iv)
)

# Store encrypted password + IV in database/file
save_credential(addr(iv), addr(encrypted), cipher_len)
```

### Pattern 3: Network Encryption

```brainhair
# Before sending over network
var message: ptr uint8 = "Secret data"
var encrypted: array[256, uint8]
var iv: array[16, uint8]

var cipher_len: int32 = aes_encrypt_string(
  message, strlen(message),
  addr(encrypted), 256,
  addr(shared_key), 32,
  addr(iv)
)

# Send IV first (16 bytes), then ciphertext
send_bytes(socket, addr(iv), 16)
send_bytes(socket, addr(encrypted), cipher_len)

# Receiver:
var recv_iv: array[16, uint8]
var recv_cipher: array[256, uint8]
recv_bytes(socket, addr(recv_iv), 16)
var recv_len: int32 = recv_bytes(socket, addr(recv_cipher), 256)

var plaintext: array[256, uint8]
aes_decrypt_string(
  addr(recv_cipher), recv_len,
  addr(plaintext), 256,
  addr(shared_key), 32,
  addr(recv_iv)
)
```

## Error Handling

Always check return values:

```brainhair
var result: int32 = aes_key_init(addr(key), 32)
if result != 0:
  print("Error: ")
  print(aes_get_error_message(result))
  return -1

result = aes_encrypt_cbc_mode(plain, cipher, length, addr(iv))
if result != 0:
  print("Encryption failed!")
  return -1
```

## Security Checklist

Before deploying AES encryption:

- [ ] Using CBC mode (not ECB)?
- [ ] Generating random IVs for each encryption?
- [ ] Using 32-byte keys (AES-256)?
- [ ] Keys from secure RNG (not hardcoded)?
- [ ] Storing IVs with ciphertext?
- [ ] Not reusing IVs with same key?
- [ ] Using authenticated encryption (HMAC) for integrity?
- [ ] Properly handling key storage/derivation?

## Testing

Test your encryption:

```bash
# Build and run test program
./bin/bhbuild userland/aes_test.bh bin/aes_test
./bin/aes_test
```

Should see:
```
✓ AES-128 test PASSED
✓ AES-256 test PASSED
✓ CBC mode test PASSED
```

## Common Mistakes

### ❌ Wrong: Reusing IV
```brainhair
var iv: array[16, uint8] = {1, 2, 3, ...}  # Fixed IV
aes_encrypt_cbc_mode(msg1, cipher1, len1, addr(iv))  # BAD
aes_encrypt_cbc_mode(msg2, cipher2, len2, addr(iv))  # BAD - same IV!
```

### ✓ Right: Random IV each time
```brainhair
var iv1: array[16, uint8]
random_bytes(addr(iv1), 16)
aes_encrypt_cbc_mode(msg1, cipher1, len1, addr(iv1))  # Good

var iv2: array[16, uint8]
random_bytes(addr(iv2), 16)
aes_encrypt_cbc_mode(msg2, cipher2, len2, addr(iv2))  # Good - different IV
```

### ❌ Wrong: Hardcoded key
```brainhair
var key: array[32, uint8] = {1, 2, 3, ...}  # BAD - predictable
```

### ✓ Right: Random or derived key
```brainhair
var key: array[32, uint8]
random_bytes(addr(key), 32)  # Good - random

# Or derive from password:
pbkdf2(password, salt, iterations, addr(key), 32)  # Good - derived
```

## Next Steps

- Read full documentation: `docs/AES_IMPLEMENTATION.md`
- Study test program: `userland/aes_test.bh`
- Learn about authenticated encryption (AES-GCM coming soon)
- Explore key derivation (PBKDF2, Argon2)
- Consider adding HMAC for message authentication

## Getting Help

AES is powerful but easy to misuse. When in doubt:
1. Use CBC mode with random IVs
2. Use AES-256 (32-byte keys)
3. Add authentication (HMAC-SHA256)
4. Never roll your own protocol
5. Test thoroughly

For more details, see `docs/AES_IMPLEMENTATION.md`.
