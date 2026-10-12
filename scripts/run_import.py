"""CLI import script for running the VoterLens import engine on an electoral roll PDF."""

import argparse
import logging
from pathlib import Path
import sys

from voterlens.config.settings import default_settings
from voterlens.database.database import DatabaseManager
from voterlens.ocr import get_ocr_engine
from voterlens.pipeline.import_pipeline import (
    ElectoralRollImportPipeline,
    ImportConfig,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger("voterlens.importer")


def main():
    parser = argparse.ArgumentParser(
        description="VoterLens Phase 1 — Electoral Roll Import & Local Database Engine"
    )
    parser.add_argument(
        "--pdf",
        type=str,
        default="tests/test-data/synthetic_kerala_roll.pdf",
        help="Path to the authorized electoral roll PDF",
    )
    parser.add_argument("--state", type=str, default="Kerala", help="State name")
    parser.add_argument(
        "--district", type=str, default="Pathanamthitta", help="District name"
    )
    parser.add_argument(
        "--ac",
        type=str,
        default="112 - Thiruvalla",
        help="Assembly constituency number and name",
    )
    parser.add_argument(
        "--roll-name",
        type=str,
        default="General Draft Electoral Roll 2026",
        help="Official roll description",
    )
    parser.add_argument(
        "--db-url",
        type=str,
        default=default_settings.database_url,
        help="SQLite database connection URL",
    )
    parser.add_argument(
        "--ocr-engine",
        type=str,
        default="auto",
        choices=["auto", "tesseract", "paddle", "mock"],
        help="OCR engine selection",
    )
    parser.add_argument(
        "--start-page",
        type=int,
        default=2,
        help="0-indexed starting page for voter card grids",
    )
    parser.add_argument(
        "--end-page",
        type=int,
        default=None,
        help="0-indexed ending page (optional)",
    )

    args = parser.parse_args()

    default_settings.ensure_directories()
    pdf_path = Path(args.pdf)
    if not pdf_path.exists():
        logger.error("Specified PDF file '%s' does not exist.", pdf_path)
        sys.exit(1)

    logger.info("Initializing SQLite database connection: %s", args.db_url)
    db_manager = DatabaseManager(database_url=args.db_url)
    db_manager.create_tables()

    logger.info("Configuring OCR engine: %s", args.ocr_engine)
    ocr = get_ocr_engine(args.ocr_engine)

    pipeline = ElectoralRollImportPipeline(
        db_manager=db_manager,
        ocr_engine=ocr,
    )

    config = ImportConfig(
        state=args.state,
        district=args.district,
        assembly_constituency=args.ac,
        roll_name=args.roll_name,
        start_page=args.start_page,
        end_page=args.end_page,
        auto_activate=True,
    )

    logger.info("Starting Electoral Roll Import Pipeline...")
    result = pipeline.run(pdf_path, config)

    print("\n" + "=" * 60)
    print("VOTERLENS IMPORT SUMMARY")
    print("=" * 60)
    print(f"Roll Version ID:  {result.roll_version_id}")
    print(f"Status:           {result.status.value}")
    print(f"Total Detected:   {result.total_detected:,}")
    print(f"Valid Records:    {result.valid_count:,}")
    print(f"Warnings:         {result.warning_count:,}")
    print(f"Photos Saved:     {result.photos_saved:,}")
    if result.error_message:
        print(f"Error:            {result.error_message}")
    print("=" * 60)

    if result.validation_report:
        print("\n" + result.validation_report.to_summary_text())

    db_manager.close()


if __name__ == "__main__":
    main()
