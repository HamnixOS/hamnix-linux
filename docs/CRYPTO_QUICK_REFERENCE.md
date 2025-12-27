# BrainhairOS Cryptography Quick Reference

Quick reference for using cryptographic functions in BrainhairOS.

## Available Algorithms

| Algorithm | Type | Key Size | Output Size | Use Case |
|-----------|------|----------|-------------|----------|
| SHA-256 | Hash | - | 256-bit (32 bytes) | Integrity, fingerprints |
| SHA-512 | Hash | - | 512-bit (64 bytes) | Ed25519 support, higher security |
| HMAC-SHA256 | MAC | any | 256-bit (32 bytes) | Message authentication |
| HMAC-SHA512 | MAC | any | 512-bit (64 bytes) | Message authentication |
| AES | Block Cipher | 128/192/256-bit | Block-based | Encryption (legacy) |
| ChaCha20 | Stream Cipher | 256-bit | Stream | Modern encryption |
| Poly1305 | MAC | 256-bit | 128-bit (16 bytes) | Authentication |
| ChaCha20-Poly1305 | AEAD | 256-bit | Ciphertext + 16-byte tag | Authenticated encryption |
| X25519 | Key Exchange | 256-bit | 256-bit (32 bytes) | ECDH key agreement |
| Ed25519 | Signature | 256-bit | 512-bit (64 bytes) | Digital signatures |
| HKDF | Key Derivation | varies | any | Derive keys from shared secret |
| PBKDF2 | Key Derivation | password | any | Password-based key derivation |

## When to Use What

### Hash (SHA-256)
✅ File integrity checks
✅ Password hashing (with salt)
✅ Digital signatures
✅ Merkle trees
❌ Encryption (hashes are one-way!)

### MAC (Poly1305)
✅ Message authentication
✅ Verify data integrity
✅ Prevent tampering
❌ Confidentiality (doesn't hide data)

### Encryption (ChaCha20)
✅ Confidentiality
✅ Fast software performance
❌ Authentication (need MAC separately)

### AEAD (ChaCha20-Poly1305)
✅ Confidentiality + Authentication
✅ Recommended for new code
✅ TLS 1.3, modern protocols
✅ Single API for both

## Quick Examples

### 1. Hash a File (SHA-256)

```brainhair
# Include lib
extern sha256_hash(data: ptr uint8, len: int32, output: ptr uint8): int32

# Hash
var data: ptr uint8 = cast[ptr uint8]("Hello")
var hash: array[32, uint8]
sha256_hash(data, 5, addr(hash[0]))
```

### 2. Encrypt Data (ChaCha20-Poly1305 AEAD)

```brainhair
# Include lib
extern aead_chacha20_poly1305_encrypt(
  plaintext: ptr uint8, plaintext_len: int32,
  aad: ptr uint8, aad_len: int32,
  key: ptr uint8, nonce: ptr uint8,
  ciphertext: ptr uint8, tag: ptr uint8
): int32

# Encrypt
var plaintext: ptr uint8 = cast[ptr uint8]("Secret")
var key: array[32, uint8]        # Generate random!
var nonce: array[12, uint8]      # Must be unique!
var ciphertext: array[16, uint8]
var tag: array[16, uint8]

aead_chacha20_poly1305_encrypt(
  plaintext, 6,
  cast[ptr uint8](0), 0,  # No AAD
  addr(key[0]), addr(nonce[0]),
  addr(ciphertext[0]), addr(tag[0])
)

# Send: ciphertext + tag + nonce (key is shared secretly)
```

### 3. Decrypt Data (ChaCha20-Poly1305 AEAD)

```brainhair
extern aead_chacha20_poly1305_decrypt(
  ciphertext: ptr uint8, ciphertext_len: int32,
  aad: ptr uint8, aad_len: int32,
  tag: ptr uint8,
  key: ptr uint8, nonce: ptr uint8,
  plaintext: ptr uint8
): int32

# Decrypt
var plaintext: array[16, uint8]
var result: int32 = aead_chacha20_poly1305_decrypt(
  addr(ciphertext[0]), 6,
  cast[ptr uint8](0), 0,
  addr(tag[0]),
  addr(key[0]), addr(nonce[0]),
  addr(plaintext[0])
)

if result == 0:
  # Success - plaintext is valid
elif result == -2:
  # AUTHENTICATION FAILED - data tampered!
  # DO NOT USE PLAINTEXT!
```

### 4. Authenticate Message (Poly1305 MAC)

```brainhair
extern poly1305_auth(tag: ptr uint8, msg: ptr uint8, len: int32, key: ptr uint8): int32

# Create MAC
var msg: ptr uint8 = cast[ptr uint8]("Authenticate me")
var key: array[32, uint8]  # Shared secret
var tag: array[16, uint8]

poly1305_auth(addr(tag[0]), msg, 15, addr(key[0]))

# Send: msg + tag
# Receiver verifies with same key
```

### 5. Verify MAC

```brainhair
extern poly1305_verify(msg: ptr uint8, len: int32, key: ptr uint8, tag: ptr uint8): int32

# Verify
var valid: int32 = poly1305_verify(msg, 15, addr(key[0]), addr(tag[0]))
if valid == 1:
  # Authentic - message not tampered
else:
  # INVALID - reject message!
```

### 6. Password Hashing (SHA-256 with Salt)

```brainhair
extern sha256_hash(data: ptr uint8, len: int32, output: ptr uint8): int32

# DON'T: Just hash password
sha256_hash(password, len, addr(hash[0]))  # ❌ Vulnerable!

# DO: Hash with salt
var salt: array[16, uint8]  # Random, unique per user
var salted_password: array[64, uint8]

# Copy salt + password into buffer
# ... copy salt and password ...

sha256_hash(addr(salted_password[0]), total_len, addr(hash[0]))

# Store: salt + hash (salt can be public)
```

## Security Checklist

### ✅ DO
- ✅ Use AEAD (ChaCha20-Poly1305) for new code
- ✅ Generate random keys (32 bytes for ChaCha20-Poly1305)
- ✅ Use unique nonces (NEVER reuse with same key!)
- ✅ Verify authentication BEFORE using decrypted data
- ✅ Use constant-time comparisons for MACs/tags
- ✅ Salt passwords before hashing
- ✅ Destroy sensitive data after use (overwrite memory)

### ❌ DON'T
- ❌ Reuse (key, nonce) pairs
- ❌ Use decrypted data before verifying authentication
- ❌ Hardcode keys in source code
- ❌ Hash passwords without salt
- ❌ Use ECB mode for block ciphers
- ❌ Invent your own crypto protocols
- ❌ Ignore authentication failures

## Common Pitfalls

### Pitfall 1: Nonce Reuse
```brainhair
# ❌ BAD: Reusing nonce
var nonce: array[12, uint8] = {1, 2, 3, ...}
encrypt(msg1, key, nonce)  # Uses nonce
encrypt(msg2, key, nonce)  # REUSES nonce - BROKEN!

# ✅ GOOD: Increment nonce
var nonce_counter: int32 = 0
# ... set nonce from counter ...
nonce_counter = nonce_counter + 1
```

### Pitfall 2: Decrypt Before Verify
```brainhair
# ❌ BAD: Use data before verifying
decrypt(ciphertext, plaintext)
use_data(plaintext)  # Might be tampered!
if verify(tag) == 0:
  # Too late!

# ✅ GOOD: Verify first (or use AEAD)
if aead_decrypt(...) == 0:
  use_data(plaintext)  # Safe - verified first
```

### Pitfall 3: No Salt on Passwords
```brainhair
# ❌ BAD: Hash password directly
hash = sha256(password)  # Rainbow table attack!

# ✅ GOOD: Use salt
hash = sha256(salt || password)
# Store both salt and hash
```

## Key Sizes Summary

| Purpose | Algorithm | Key Size | Notes |
|---------|-----------|----------|-------|
| Encryption (AEAD) | ChaCha20-Poly1305 | 32 bytes (256-bit) | Recommended |
| Encryption (Stream) | ChaCha20 | 32 bytes (256-bit) | Need MAC separately |
| Encryption (Block) | AES-256 | 32 bytes (256-bit) | Legacy |
| Authentication | Poly1305 | 32 bytes (256-bit) | Use with encryption |
| Hashing | SHA-256 | - (no key) | 32-byte output |

## Nonce Sizes

| Algorithm | Nonce Size | Uniqueness Required |
|-----------|------------|---------------------|
| ChaCha20-Poly1305 | 12 bytes (96-bit) | ✅ Critical - NEVER reuse! |
| AES-GCM | 12 bytes (96-bit) | ✅ Critical |
| AES-CBC | 16 bytes (128-bit) | ⚠️ IV should be random |

## Generating Random Values

```brainhair
# Use kernel RNG
extern syscall3(num: int32, arg1: int32, arg2: int32, arg3: int32): int32
const SYS_GETRANDOM: int32 = 80

var random_bytes: array[32, uint8]
syscall3(SYS_GETRANDOM, cast[int32](addr(random_bytes[0])), 32, 0)
```

## Error Codes

| Return Value | Meaning |
|--------------|---------|
| 0 | Success |
| -1 | General error (invalid params) |
| -2 | Authentication failed (AEAD decrypt) |

## Performance Tips

1. **Use AEAD**: Single pass for encrypt + auth
2. **Batch operations**: Encrypt multiple messages with different nonces
3. **Buffer sizes**: Align to block boundaries when possible
4. **Avoid copies**: Work in-place where possible
5. **Precompute**: Generate nonces/keys once, reuse appropriately

## File Encryption Pattern

```brainhair
# Encrypt file
var file_key: array[32, uint8]    # Random per file
var nonce_counter: int32 = 0

# For each 4KB chunk
while has_data:
  var chunk: array[4096, uint8]
  var encrypted: array[4096, uint8]
  var tag: array[16, uint8]
  var nonce: array[12, uint8]

  # Generate nonce from counter
  # ... set nonce = counter in little-endian ...

  aead_chacha20_poly1305_encrypt(
    addr(chunk[0]), chunk_size,
    cast[ptr uint8](0), 0,
    addr(file_key[0]), addr(nonce[0]),
    addr(encrypted[0]), addr(tag[0])
  )

  # Write: nonce || tag || encrypted_chunk

  nonce_counter = nonce_counter + 1
```

## Network Packet Pattern

```brainhair
# Encrypt packet with header as AAD
var header: ptr uint8 = cast[ptr uint8]("PKT-HEADER-DATA")
var payload: ptr uint8 = cast[ptr uint8]("payload data")
var key: array[32, uint8]
var nonce: array[12, uint8]  # From sequence number
var encrypted: array[256, uint8]
var tag: array[16, uint8]

aead_chacha20_poly1305_encrypt(
  payload, payload_len,
  header, header_len,    # AAD - authenticated but not encrypted
  addr(key[0]), addr(nonce[0]),
  addr(encrypted[0]), addr(tag[0])
)

# Send: header || encrypted || tag
# Header is readable but tamper-proof
```

## Unified Crypto API (lib/crypto.bh)

The high-level crypto library provides a unified interface to all crypto functions:

```brainhair
import "lib/crypto"

# Hashing
crypto_sha256(data, len, output)
crypto_sha512(data, len, output)

# HMAC
crypto_hmac_sha256(key, key_len, data, data_len, output)
crypto_hmac_sha512(key, key_len, data, data_len, output)

# Random
crypto_random_bytes(buf, len)
crypto_random_int()

# Key Exchange (X25519)
crypto_x25519_keypair(private_key, public_key)
crypto_x25519_shared(shared, private_key, their_public_key)

# Digital Signatures (Ed25519)
crypto_ed25519_keypair(seed, public_key, private_key)
crypto_ed25519_sign(signature, message, msg_len, private_key)
crypto_ed25519_verify(signature, message, msg_len, public_key)

# AEAD (ChaCha20-Poly1305)
crypto_aead_encrypt(key, nonce, plaintext, pt_len, aad, aad_len, ciphertext)
crypto_aead_decrypt(key, nonce, ciphertext, ct_len, aad, aad_len, plaintext)

# Key Derivation
crypto_hkdf_sha256(salt, salt_len, ikm, ikm_len, info, info_len, okm, okm_len)
crypto_pbkdf2_sha256(password, pass_len, salt, salt_len, iterations, output, out_len)

# Utilities
crypto_to_hex(input, len, output)
crypto_from_hex(input, len, output)
crypto_compare(a, b, len)  # Constant-time comparison
```

### Digital Signature Example (Ed25519)

```brainhair
import "lib/crypto"

# Generate keypair
var public_key: array[32, uint8]
var private_key: array[64, uint8]
crypto_ed25519_keypair(cast[ptr uint8](0), addr(public_key[0]), addr(private_key[0]))

# Sign message
var message: ptr uint8 = cast[ptr uint8]("Hello, World!")
var signature: array[64, uint8]
crypto_ed25519_sign(addr(signature[0]), message, 13, addr(private_key[0]))

# Verify signature
var result: int32 = crypto_ed25519_verify(addr(signature[0]), message, 13, addr(public_key[0]))
if result == 0:
  # Valid signature
```

### Key Exchange Example (X25519)

```brainhair
import "lib/crypto"

# Alice generates keypair
var alice_private: array[32, uint8]
var alice_public: array[32, uint8]
crypto_x25519_keypair(addr(alice_private[0]), addr(alice_public[0]))

# Bob generates keypair
var bob_private: array[32, uint8]
var bob_public: array[32, uint8]
crypto_x25519_keypair(addr(bob_private[0]), addr(bob_public[0]))

# Exchange public keys, then compute shared secret
var alice_shared: array[32, uint8]
var bob_shared: array[32, uint8]
crypto_x25519_shared(addr(alice_shared[0]), addr(alice_private[0]), addr(bob_public[0]))
crypto_x25519_shared(addr(bob_shared[0]), addr(bob_private[0]), addr(alice_public[0]))
# alice_shared == bob_shared
```

### Password Hashing Example (PBKDF2)

```brainhair
import "lib/crypto"

var password: ptr uint8 = cast[ptr uint8]("mypassword")
var salt: array[16, uint8]
crypto_random_bytes(addr(salt[0]), 16)  # Random salt

var derived_key: array[32, uint8]
crypto_pbkdf2_sha256(password, 10, addr(salt[0]), 16, 100000, addr(derived_key[0]), 32)
# Store salt + derived_key for verification later
```

## Libraries Location

```
# Kernel Assembly
kernel/poly1305.asm         - Poly1305 MAC kernel code
kernel/chacha20.asm         - ChaCha20 cipher kernel code
kernel/sha256.asm           - SHA-256 hash kernel code
kernel/sha512.asm           - SHA-512 hash kernel code
kernel/aes.asm              - AES cipher kernel code
kernel/x25519.asm           - X25519 key exchange kernel code
kernel/ed25519.asm          - Ed25519 signatures kernel code
kernel/rng.asm              - Random number generator

# Userland Libraries
lib/crypto.bh               - Unified high-level crypto API
lib/hmac.bh                 - HMAC, HKDF, PBKDF2
lib/poly1305.bh             - Poly1305 userland API
lib/chacha20.bh             - ChaCha20 userland API
lib/aead.bh                 - AEAD construction
lib/sha256.bh               - SHA-256 userland API
lib/aes.bh                  - AES userland API
lib/x25519.bh               - X25519 userland API
lib/ed25519.bh              - Ed25519 userland API
lib/random.bh               - Random number utilities
lib/base64.bh               - Base64/Hex encoding
```

## Test Programs

```
userland/chacha20_poly1305_test.bh
userland/sha256_test.bh
userland/aes_test.bh
```

Run tests:
```bash
./bin/chacha20_poly1305_test
./bin/sha256_test
./bin/aes_test
```

## Further Reading

- Full documentation: `docs/CHACHA20_POLY1305.md`
- RFC 8439: ChaCha20 and Poly1305 specification
- lib/aead.bh: Complete API with comments
- Test programs: Working examples

---

**Quick Reference Version:** 1.0
**Last Updated:** 2025
**For:** BrainhairOS Developers
