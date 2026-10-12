"""Pytest configuration and shared test fixtures."""

import os
from pathlib import Path
import tempfile
import pytest

from voterlens.database.database import DatabaseManager
from voterlens.ocr.mock_engine import MockOCREngine
from voterlens.photographs.processor import PhotoProcessor
from scripts.generate_synthetic_roll import generate_synthetic_roll_pdf


@pytest.fixture
def temp_dir():
    """Provide a temporary directory cleaned up after test run."""
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp_d:
        yield Path(tmp_d)


@pytest.fixture
def in_memory_db():
    """In-memory SQLite DatabaseManager for fast isolated testing."""
    manager = DatabaseManager(database_url="sqlite:///:memory:")
    manager.create_tables()
    yield manager
    manager.close()


@pytest.fixture
def file_db(temp_dir):
    """File-based SQLite DatabaseManager to test persistent file operations."""
    db_file = temp_dir / "test_voterlens.db"
    manager = DatabaseManager(database_url=f"sqlite:///{db_file}")
    manager.create_tables()
    yield manager
    manager.close()


@pytest.fixture
def mock_ocr():
    """Deterministic Mock OCR engine."""
    return MockOCREngine()


@pytest.fixture
def temp_photo_processor(temp_dir):
    """Photo processor configured with temporary photos directory."""
    photos_dir = temp_dir / "photos"
    return PhotoProcessor(base_photos_dir=photos_dir)


@pytest.fixture(scope="session")
def sample_synthetic_pdf():
    """Generate or retrieve cached synthetic Kerala electoral roll PDF."""
    pdf_path = Path("tests/test-data/synthetic_kerala_roll.pdf")
    if not pdf_path.exists():
        generate_synthetic_roll_pdf(pdf_path, num_voters=6)
    return pdf_path
