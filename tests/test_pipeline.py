"""Tests for end-to-end electoral roll import pipeline and safety guarantees."""

from pathlib import Path
from voterlens.database.database import DatabaseManager
from voterlens.database.models import RollVersionStatus
from voterlens.database.repository import ElectoralRollRepository, VoterRepository
from voterlens.ocr.mock_engine import MockOCREngine
from voterlens.pdf.processor import PDFProcessor
from voterlens.photographs.extractor import PhotoExtractor
from voterlens.photographs.processor import PhotoProcessor
from voterlens.pipeline.import_pipeline import (
    ElectoralRollImportPipeline,
    ImportConfig,
)


def test_end_to_end_pipeline_import(temp_dir, sample_synthetic_pdf):
    """Run full import pipeline on synthetic Kerala roll and verify DB and photos."""
    db_file = temp_dir / "pipeline_test.db"
    db_manager = DatabaseManager(database_url=f"sqlite:///{db_file}")
    db_manager.create_tables()

    photos_dir = temp_dir / "photos"
    photo_proc = PhotoProcessor(base_photos_dir=photos_dir)

    pipeline = ElectoralRollImportPipeline(
        db_manager=db_manager,
        ocr_engine=MockOCREngine(),
        photo_processor=photo_proc,
        photo_extractor=PhotoExtractor(),
        pdf_processor=PDFProcessor(dpi=200),
    )

    config = ImportConfig(
        state="Kerala",
        district="Pathanamthitta",
        assembly_constituency="112 - Thiruvalla",
        roll_name="Final Electoral Roll 2026",
        start_page=2,  # voter grid starts on page 2 (0-indexed page 2 is page 3)
        end_page=3,
        auto_activate=True,
    )

    result = pipeline.run(sample_synthetic_pdf, config)

    # 1. Pipeline result checks
    assert result.status == RollVersionStatus.ACTIVE
    assert result.total_detected >= 6
    assert result.valid_count >= 1
    assert result.roll_version_id != ""

    # 2. Database verification
    with db_manager.session() as session:
        roll_repo = ElectoralRollRepository(session)
        voter_repo = VoterRepository(session)

        roll = roll_repo.get_active_roll("Kerala", "Pathanamthitta", "112 - Thiruvalla")
        assert roll is not None
        assert roll.id == result.roll_version_id
        assert roll.status == RollVersionStatus.ACTIVE

        # Check voters
        voters = voter_repo.search_voters(roll_version_id=roll.id, limit=50)
        assert len(voters) >= 6

        # Check specific voter fields
        v1 = [v for v in voters if v.serial_number == 1][0]
        assert v1.epic_number == "KLM1092831"
        assert "സുരേഷ്" in v1.name or "Suresh" in v1.name
        assert v1.age == 42
        assert v1.gender == "M"

        # Check photos saved
        assert result.photos_saved > 0
        assert v1.photo_path is not None
        assert Path(photos_dir / roll.id / "v_00001.jpg").exists()

        # Check import report persisted
        assert roll.import_report is not None
        assert roll.import_report.total_detected >= 6

    db_manager.close()


def test_pipeline_failed_import_leaves_active_roll_untouched(temp_dir, sample_synthetic_pdf):
    """Verify that an import error leaves previous active roll intact and marks new roll FAILED."""
    db_file = temp_dir / "failure_test.db"
    db_manager = DatabaseManager(database_url=f"sqlite:///{db_file}")
    db_manager.create_tables()

    # Create and activate an existing roll
    with db_manager.session() as session:
        roll_repo = ElectoralRollRepository(session)
        existing_active = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="Previous Active Roll 2025",
        )
        existing_id = existing_active.id
        roll_repo.activate_roll(existing_id)

    # Pipeline configured with a bad OCR engine that raises an exception
    class FailingOCREngine(MockOCREngine):
        def extract_text_and_boxes(self, *args, **kwargs):
            raise RuntimeError("Fatal OCR engine failure during processing")

    pipeline = ElectoralRollImportPipeline(
        db_manager=db_manager,
        ocr_engine=FailingOCREngine(),
        pdf_processor=PDFProcessor(),
    )

    # Force scanned mode so OCR engine is called
    class DummyPDFProcessor(PDFProcessor):
        def extract_card_digital_text(self, *args, **kwargs):
            return ""  # return empty so OCR is invoked

    pipeline.pdf_processor = DummyPDFProcessor()

    config = ImportConfig(
        state="Kerala",
        district="Pathanamthitta",
        assembly_constituency="112 - Thiruvalla",
        roll_name="New Failing Roll 2026",
        start_page=2,
        end_page=3,
    )

    result = pipeline.run(sample_synthetic_pdf, config)

    # Verify result status is FAILED
    assert result.status == RollVersionStatus.FAILED

    # Verify existing active roll is still ACTIVE
    with db_manager.session() as session:
        roll_repo = ElectoralRollRepository(session)
        active_roll = roll_repo.get_active_roll("Kerala", "Pathanamthitta", "112 - Thiruvalla")
        assert active_roll is not None
        assert active_roll.id == existing_id
        assert active_roll.roll_name == "Previous Active Roll 2025"

        # Check that the failed roll was marked FAILED
        failed_roll = roll_repo.get_roll_by_id(result.roll_version_id)
        assert failed_roll.status == RollVersionStatus.FAILED

    db_manager.close()
