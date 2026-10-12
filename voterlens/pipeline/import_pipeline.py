"""Electoral roll import pipeline coordinating end-to-end processing with rollback safety."""

from dataclasses import dataclass, field
import json
import logging
from pathlib import Path
from typing import Any, Optional
import pymupdf

from voterlens.database.database import DatabaseManager
from voterlens.database.models import ImportReportRecord, RollVersionStatus
from voterlens.database.repository import ElectoralRollRepository, VoterRepository
from voterlens.downloader.authorized_loader import AuthorizedRollSource
from voterlens.normalizer.text_normalizer import (
    normalize_epic,
    normalize_house_number,
    normalize_name,
)
from voterlens.ocr.engine import BaseOCREngine
from voterlens.parser.voter_parser import ParsedVoterRecord, VoterParser
from voterlens.pdf.processor import PDFProcessor
from voterlens.photographs.extractor import PhotoExtractor
from voterlens.photographs.processor import PhotoProcessor
from voterlens.validator.voter_validator import ValidationReport, VoterValidator

logger = logging.getLogger(__name__)


@dataclass
class ImportConfig:
    """Configuration options for an electoral roll import run."""
    state: str = "Kerala"
    district: str = "Pathanamthitta"
    assembly_constituency: str = "112 - Thiruvalla"
    roll_name: str = "Final Electoral Roll 2026"
    roll_type: str = "GENERAL"
    publication_date: Optional[str] = "2026-01-05"
    source_reference: Optional[str] = None
    auto_activate: bool = True
    start_page: int = 2  # 0-indexed; pages 0 & 1 typically contain summary/title
    end_page: Optional[int] = None
    max_voters: Optional[int] = None
    grid_cols: int = 3
    grid_rows: int = 10
    ocr_languages: str = "mal+eng"
    extract_photos: bool = True


@dataclass
class ImportPipelineResult:
    """Summary result returned after pipeline execution."""
    roll_version_id: str
    status: RollVersionStatus
    total_detected: int = 0
    valid_count: int = 0
    warning_count: int = 0
    invalid_count: int = 0
    photos_saved: int = 0
    validation_report: Optional[ValidationReport] = None
    error_message: Optional[str] = None


class ElectoralRollImportPipeline:
    """Orchestrates PDF inspection, OCR, extraction, validation, and safe DB insertion."""

    def __init__(
        self,
        db_manager: DatabaseManager,
        ocr_engine: BaseOCREngine,
        photo_processor: Optional[PhotoProcessor] = None,
        photo_extractor: Optional[PhotoExtractor] = None,
        pdf_processor: Optional[PDFProcessor] = None,
        parser: Optional[VoterParser] = None,
        validator: Optional[VoterValidator] = None,
    ):
        self.db_manager = db_manager
        self.ocr_engine = ocr_engine
        self.photo_processor = photo_processor or PhotoProcessor()
        self.photo_extractor = photo_extractor or PhotoExtractor()
        self.pdf_processor = pdf_processor or PDFProcessor()
        self.parser = parser or VoterParser()
        self.validator = validator or VoterValidator()

    def run(
        self,
        pdf_path: str | Path,
        config: Optional[ImportConfig] = None,
    ) -> ImportPipelineResult:
        """Run the import pipeline with safety guarantees."""
        cfg = config or ImportConfig()
        pdf_file, sha256_checksum = AuthorizedRollSource.verify_and_prepare_source(pdf_path)

        # 1. PDF Inspection
        inspection = self.pdf_processor.inspect(pdf_file)
        logger.info(
            "Inspected PDF '%s': %d pages, encrypted=%s",
            pdf_file.name,
            inspection.page_count,
            inspection.is_encrypted,
        )

        # 2. Initialize roll version in IMPORTING state
        source_ref = cfg.source_reference or f"SHA256:{sha256_checksum[:16]}"
        roll_version_id: Optional[str] = None

        with self.db_manager.session() as session:
            roll_repo = ElectoralRollRepository(session)
            roll = roll_repo.create_roll_version(
                state=cfg.state,
                district=cfg.district,
                assembly_constituency=cfg.assembly_constituency,
                roll_name=cfg.roll_name,
                roll_type=cfg.roll_type,
                publication_date=cfg.publication_date,
                source_reference=source_ref,
            )
            roll_version_id = roll.id

        try:
            # 3. Process Pages and Extract Voter Cards
            extracted_records: list[dict[str, Any]] = []
            photos_saved_count = 0
            doc = pymupdf.open(str(pdf_file))

            total_pages = len(doc)
            start_p = min(max(0, cfg.start_page), total_pages - 1)
            end_p = min(cfg.end_page if cfg.end_page is not None else total_pages, total_pages)

            # Extract document-level title/header metadata if possible
            doc_meta: dict[str, Any] = {}
            if total_pages > 0:
                p0_text = doc[0].get_text()
                doc_meta = self.parser.extract_header_metadata(p0_text)

            voters_processed = 0

            for p_num in range(start_p, end_p):
                page = doc[p_num]
                page_text = page.get_text()
                page_meta = {**doc_meta, **self.parser.extract_header_metadata(page_text)}

                page_img = self.pdf_processor.render_page(doc, p_num)
                card_regions = self.pdf_processor.segment_grid_cards(
                    page_img,
                    page_number=p_num,
                    cols=cfg.grid_cols,
                    rows=cfg.grid_rows,
                )

                for card_reg in card_regions:
                    if cfg.max_voters and voters_processed >= cfg.max_voters:
                        break

                    # Try digital text layer from PDF card region first
                    scale = self.pdf_processor.zoom
                    bx, by, bw, bh = card_reg.bbox
                    pt_bbox = (bx / scale, by / scale, (bx + bw) / scale, (by + bh) / scale)
                    digital_text = self.pdf_processor.extract_card_digital_text(page, pt_bbox)

                    if digital_text and (
                        "പേര്" in digital_text
                        or "name" in digital_text.lower()
                        or "പ്രായം" in digital_text
                        or "age" in digital_text.lower()
                    ):
                        card_text = digital_text
                        card_confidence = 1.0
                    else:
                        # Scanned PDF: run OCR pass
                        ocr_res = self.ocr_engine.extract_text_and_boxes(
                            card_reg.image, languages=cfg.ocr_languages
                        )
                        card_text = ocr_res.full_text
                        card_confidence = ocr_res.average_confidence

                    # Extract card fields
                    parsed: Optional[ParsedVoterRecord] = self.parser.parse_card_text(
                        card_text=card_text,
                        default_meta=page_meta,
                        confidence=card_confidence,
                        photo_box=card_reg.bbox,
                    )

                    # Filter out cards that are completely empty / blank
                    if not parsed or (not parsed.name and not parsed.epic_number and not parsed.serial_number):
                        continue

                    # If serial is 0, assign sequential counter based on batch
                    if parsed.serial_number == 0:
                        parsed.serial_number = voters_processed + 1

                    # Process photo if present
                    photo_rel_path: Optional[str] = None
                    if cfg.extract_photos:
                        cropped_photo = self.photo_extractor.crop_photo_from_card(card_reg.image)
                        if cropped_photo:
                            temp_voter_id = f"v_{parsed.serial_number:05d}"
                            photo_rel_path = self.photo_processor.save_voter_photo(
                                image=cropped_photo,
                                roll_version_id=roll_version_id,
                                voter_id=temp_voter_id,
                            )
                            if photo_rel_path:
                                photos_saved_count += 1

                    rec_dict = {
                        "serial_number": parsed.serial_number,
                        "epic_number": parsed.epic_number,
                        "name": parsed.name,
                        "normalized_name": parsed.normalized_name,
                        "relative_name": parsed.relative_name,
                        "normalized_relative_name": parsed.normalized_relative_name,
                        "relative_type": parsed.relative_type,
                        "house_number": parsed.house_number,
                        "normalized_house_number": parsed.normalized_house_number,
                        "age": parsed.age,
                        "gender": parsed.gender,
                        "part_number": parsed.part_number or page_meta.get("part_number", "1"),
                        "section_number": parsed.section_number or page_meta.get("section_number", "1"),
                        "section_name": parsed.section_name or page_meta.get("section_name", ""),
                        "polling_station_name": parsed.polling_station_name or page_meta.get("polling_station_name", ""),
                        "polling_station_address": parsed.polling_station_address or page_meta.get("polling_station_address", ""),
                        "photo_path": photo_rel_path,
                        "ocr_confidence": parsed.ocr_confidence,
                        "raw_data": json.dumps(
                            {"raw_text": parsed.raw_text, "page": p_num, "bbox": card_reg.bbox}
                        ),
                    }
                    extracted_records.append(rec_dict)
                    voters_processed += 1

                if cfg.max_voters and voters_processed >= cfg.max_voters:
                    break

            doc.close()

            # 4. Validation Layer
            report = self.validator.validate_dataset(extracted_records)
            summary_report_text = report.to_summary_text()
            logger.info("Validation Report:\n%s", summary_report_text)

            # 5. Database Insertion & Report Archival
            with self.db_manager.session() as session:
                voter_repo = VoterRepository(session)
                voter_repo.insert_voters_batch(roll_version_id, extracted_records)

                # Persist validation report
                warnings_dict = report.issue_counts_by_code
                report_rec = ImportReportRecord(
                    roll_version_id=roll_version_id,
                    total_detected=report.total_detected,
                    valid_count=report.valid_count,
                    warning_count=report.warning_count,
                    invalid_count=report.invalid_count,
                    warnings_json=json.dumps(warnings_dict),
                    summary_text=summary_report_text,
                )
                session.add(report_rec)

                # 6. Activation & Dataset Locking
                roll_repo = ElectoralRollRepository(session)
                if cfg.auto_activate:
                    roll_repo.activate_roll(roll_version_id)
                    final_status = RollVersionStatus.ACTIVE
                else:
                    final_status = RollVersionStatus.IMPORTING

            return ImportPipelineResult(
                roll_version_id=roll_version_id,
                status=final_status,
                total_detected=report.total_detected,
                valid_count=report.valid_count,
                warning_count=report.warning_count,
                invalid_count=report.invalid_count,
                photos_saved=photos_saved_count,
                validation_report=report,
            )

        except Exception as e:
            logger.exception("Import pipeline encountered an error: %s", e)
            # Safe failure guarantee: Mark new roll as FAILED, leaving any previous active roll untouched
            if roll_version_id:
                with self.db_manager.session() as session:
                    roll_repo = ElectoralRollRepository(session)
                    roll_repo.mark_roll_failed(roll_version_id)

            return ImportPipelineResult(
                roll_version_id=roll_version_id or "",
                status=RollVersionStatus.FAILED,
                error_message=str(e),
            )
