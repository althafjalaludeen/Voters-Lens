"""Database connection and session lifecycle management."""

from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from typing import Optional

from sqlalchemy import create_engine, event, text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from voterlens.database.models import Base


@event.listens_for(Engine, "connect")
def set_sqlite_pragma(dbapi_connection, connection_record):
    """Ensure SQLite is configured for robust local performance and data integrity."""
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA synchronous=NORMAL")
    cursor.close()


class DatabaseManager:
    """Manages SQLite database connection, schema setup, and sessions."""

    def __init__(self, database_url: str = "sqlite:///data/voterlens.db"):
        self.database_url = database_url
        
        # Ensure parent directory exists for local file databases
        if database_url.startswith("sqlite:///") and ":memory:" not in database_url:
            db_path = database_url.replace("sqlite:///", "")
            Path(db_path).parent.mkdir(parents=True, exist_ok=True)

        self.engine = create_engine(
            self.database_url,
            echo=False,
            future=True,
        )
        self.session_factory = sessionmaker(
            bind=self.engine,
            expire_on_commit=False,
        )

    def _migrate_existing_schema(self) -> None:
        """Non-destructive migration to add Phase 2 columns to any pre-existing database."""
        with self.engine.connect() as conn:
            # Check roll_versions columns
            try:
                roll_cols = [row[1] for row in conn.execute(text("PRAGMA table_info(roll_versions)")).fetchall()]
                if roll_cols and "checksum_hash" not in roll_cols:
                    conn.execute(text("ALTER TABLE roll_versions ADD COLUMN checksum_hash VARCHAR(64)"))
                    conn.commit()
            except Exception:
                pass

            # Check field_status columns
            try:
                fs_cols = [row[1] for row in conn.execute(text("PRAGMA table_info(field_status)")).fetchall()]
                if fs_cols:
                    if "phone_number" not in fs_cols:
                        conn.execute(text("ALTER TABLE field_status ADD COLUMN phone_number VARCHAR(50)"))
                    if "review_status" not in fs_cols:
                        conn.execute(text("ALTER TABLE field_status ADD COLUMN review_status VARCHAR(20) DEFAULT 'NOT_REVIEWED'"))
                    if "review_reasons" not in fs_cols:
                        conn.execute(text("ALTER TABLE field_status ADD COLUMN review_reasons TEXT"))
                    if "reviewed_by" not in fs_cols:
                        conn.execute(text("ALTER TABLE field_status ADD COLUMN reviewed_by VARCHAR(100)"))
                    if "reviewed_at" not in fs_cols:
                        conn.execute(text("ALTER TABLE field_status ADD COLUMN reviewed_at TIMESTAMP"))
                    conn.commit()
            except Exception:
                pass

    def create_tables(self) -> None:
        """Create all tables defined in models and run schema migrations if upgrading."""
        Base.metadata.create_all(self.engine)
        self._migrate_existing_schema()

    def drop_tables(self) -> None:
        """Drop all tables (used primarily in test fixtures)."""
        Base.metadata.drop_all(self.engine)

    def close(self) -> None:
        """Dispose engine connections and release SQLite file locks."""
        self.engine.dispose()

    @contextmanager
    def session(self) -> Generator[Session, None, None]:
        """Provide a transactional scope around a series of operations."""
        session: Session = self.session_factory()
        try:
            yield session
            session.commit()
        except Exception:
            session.rollback()
            raise
        finally:
            session.close()


def get_db_manager(database_url: Optional[str] = None) -> DatabaseManager:
    """Factory helper to acquire a DatabaseManager."""
    from voterlens.config.settings import default_settings
    url = database_url or default_settings.database_url
    return DatabaseManager(database_url=url)
