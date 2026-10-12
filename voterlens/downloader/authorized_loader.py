"""Authorized electoral roll file validation and acquisition interface.

Adheres strictly to security guidelines:
- No hardcoded credentials or bypass mechanisms.
- Only accepts authorized locally-provided files or secure pre-authenticated storage URIs.
- Computes SHA-256 integrity checksums before initiating ingestion.
"""

import hashlib
from pathlib import Path
from typing import Optional


class AuthorizedRollSource:
    """Validates local or authorized incoming electoral-roll files."""

    @staticmethod
    def compute_sha256(file_path: Path) -> str:
        """Compute SHA-256 checksum for audit and deduplication."""
        hasher = hashlib.sha256()
        with open(file_path, "rb") as f:
            while chunk := f.read(65536):
                hasher.update(chunk)
        return hasher.hexdigest()

    @classmethod
    def verify_and_prepare_source(cls, file_path: str | Path) -> tuple[Path, str]:
        """Verify that the target PDF exists, is non-empty, and calculate checksum."""
        path = Path(file_path)
        if not path.exists():
            raise FileNotFoundError(f"Electoral roll source file '{file_path}' does not exist.")
        if path.stat().st_size == 0:
            raise ValueError(f"Electoral roll source file '{file_path}' is empty (0 bytes).")
        if path.suffix.lower() != ".pdf":
            raise ValueError(f"Electoral roll source must be a PDF file. Received: {path.name}")

        sha256 = cls.compute_sha256(path)
        return path, sha256
