"""Configuration settings for VoterLens."""

from pathlib import Path
from pydantic import BaseModel, Field


class Settings(BaseModel):
    """Application configuration for local import and storage."""

    base_dir: Path = Field(default_factory=lambda: Path.cwd())
    data_dir: Path = Field(default_factory=lambda: Path.cwd() / "data")
    photos_dir: Path = Field(default_factory=lambda: Path.cwd() / "photos")
    database_url: str = "sqlite:///data/voterlens.db"
    
    # OCR settings
    ocr_engine: str = "auto"  # 'tesseract', 'paddle', 'mock', 'auto'
    ocr_languages: str = "mal+eng"  # Malayalam + English default
    tesseract_cmd: str | None = None
    
    # Validation settings
    min_voter_age: int = 18
    max_voter_age: int = 125
    allow_unverified_records: bool = True  # whether invalid/warning records are still retained with flags
    
    def ensure_directories(self) -> None:
        """Create necessary directories if they don't exist."""
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.photos_dir.mkdir(parents=True, exist_ok=True)


default_settings = Settings()
