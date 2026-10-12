"""Cryptographic utilities for VoterLens Offline Sync using AES-256-GCM."""

import os
import secrets
from typing import Optional, Tuple

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC


class CryptoError(Exception):
    """Base exception for synchronization cryptographic operations."""
    pass


class AuthenticationError(CryptoError):
    """Raised when ciphertext authentication or integrity verification fails."""
    pass


class KeyDerivationError(CryptoError):
    """Raised when key derivation fails."""
    pass


class WeakPassphraseError(CryptoError):
    """Raised when a transfer passphrase fails minimum entropy or security policy."""
    pass


PBKDF2_ITERATIONS = 100_000
SALT_SIZE_BYTES = 16
NONCE_SIZE_BYTES = 12  # Standard 96-bit nonce for AES-GCM
KEY_SIZE_BYTES = 32    # 256 bits for AES-256

WEAK_PASSPHRASES = {
    "password", "12345678", "admin", "voterlens", "qwerty", "letmein", "welcome", "1234567890", "syncpass"
}


def validate_transfer_passphrase(passphrase: str) -> None:
    """Validate human-created transfer passphrase against security policy.
    
    Policy:
    - Non-empty
    - At least 8 characters
    - Cannot be a trivial common dictionary password
    """
    if not passphrase:
        raise WeakPassphraseError("Transfer passphrase cannot be empty")
    if len(passphrase.strip()) < 8:
        raise WeakPassphraseError(
            f"Transfer passphrase is too short ({len(passphrase.strip())} chars). "
            f"Minimum 8 characters required."
        )
    if passphrase.strip().lower() in WEAK_PASSPHRASES:
        raise WeakPassphraseError(
            f"Transfer passphrase '{passphrase}' is too common/weak. "
            f"Please choose a stronger passphrase."
        )


def generate_transfer_secret(length: int = 24) -> str:
    """Generate a high-entropy cryptographically secure transfer secret."""
    alphabet = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def generate_random_bytes(length: int) -> bytes:
    """Generate cryptographically secure pseudo-random bytes."""
    return secrets.token_bytes(length)


def generate_device_token() -> str:
    """Generate a high-entropy hex string token."""
    return secrets.token_hex(16)


def derive_key(passphrase: str, salt: bytes, iterations: int = PBKDF2_ITERATIONS) -> bytes:
    """Derive a 256-bit symmetric encryption key from a passphrase using PBKDF2-HMAC-SHA256.
    
    Args:
        passphrase: Transfer passphrase or pairing secret.
        salt: Random 16-byte cryptographic salt.
        iterations: Number of hash iterations (default 100,000).
        
    Returns:
        32-byte (256-bit) symmetric key.
    """
    if not passphrase:
        raise KeyDerivationError("Passphrase cannot be empty")
    if len(salt) < 16:
        raise KeyDerivationError("Salt must be at least 16 bytes")

    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=KEY_SIZE_BYTES,
        salt=salt,
        iterations=iterations,
    )
    return kdf.derive(passphrase.encode("utf-8"))


def encrypt_payload(
    plaintext: bytes,
    key: bytes,
    associated_data: Optional[bytes] = None,
) -> Tuple[bytes, bytes, bytes]:
    """Encrypt payload using AES-256-GCM with Additional Authenticated Data (AAD).
    
    Args:
        plaintext: The raw bytes to encrypt.
        key: 32-byte AES-256 key.
        associated_data: Unencrypted header metadata bound to the authentication tag.
        
    Returns:
        Tuple of (ciphertext, nonce, salt)
    """
    if len(key) != KEY_SIZE_BYTES:
        raise CryptoError(f"AES-256 requires 32-byte key, got {len(key)}")

    # Generate a fresh, unique 96-bit nonce for this specific encryption
    nonce = generate_random_bytes(NONCE_SIZE_BYTES)
    aesgcm = AESGCM(key)

    # AESGCM.encrypt in cryptography library appends the 16-byte authentication tag to ciphertext
    ciphertext_with_tag = aesgcm.encrypt(nonce, plaintext, associated_data)
    
    return ciphertext_with_tag, nonce


def decrypt_payload(
    ciphertext_with_tag: bytes,
    key: bytes,
    nonce: bytes,
    associated_data: Optional[bytes] = None,
) -> bytes:
    """Decrypt and verify ciphertext using AES-256-GCM.
    
    Args:
        ciphertext_with_tag: Ciphertext with 16-byte GCM authentication tag appended.
        key: 32-byte AES-256 key.
        nonce: 12-byte nonce used during encryption.
        associated_data: Unencrypted header metadata that was bound during encryption.
        
    Returns:
        Decrypted plaintext bytes.
        
    Raises:
        AuthenticationError: If ciphertext, tag, nonce, or associated data was modified.
    """
    if len(key) != KEY_SIZE_BYTES:
        raise CryptoError(f"AES-256 requires 32-byte key, got {len(key)}")
    if len(nonce) != NONCE_SIZE_BYTES:
        raise CryptoError(f"AES-GCM requires 12-byte nonce, got {len(nonce)}")

    aesgcm = AESGCM(key)
    try:
        plaintext = aesgcm.decrypt(nonce, ciphertext_with_tag, associated_data)
        return plaintext
    except InvalidTag as exc:
        raise AuthenticationError(
            "Cryptographic authentication failed: packet ciphertext was modified, "
            "corrupted, or decrypted with an incorrect transfer key"
        ) from exc
    except Exception as exc:
        raise CryptoError(f"Decryption failed: {str(exc)}") from exc
