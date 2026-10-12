"""Manual review and verification workflow service."""

from typing import Optional
from sqlalchemy import select
from sqlalchemy.orm import Session

from voterlens.database.models import FieldStatus, ReviewStatusType, Voter
from voterlens.database.repository import FieldStatusRepository, VoterRepository
from voterlens.dto.filter_dto import ReviewStatusFilter, SearchCriteria
from voterlens.dto.voter_dto import VoterListResponse, VoterSearchResult
from voterlens.services.audit_service import AuditService
from voterlens.services.security import Permission, SecurityContext


class ReviewService:
    """Manages the internal manual review queue for records with OCR/extraction anomalies.
    
    CRITICAL:
    Reviewing a record NEVER modifies official electoral data.
    """

    def __init__(self, session: Session):
        self.session = session
        self.voter_repo = VoterRepository(session)
        self.field_repo = FieldStatusRepository(session)
        self.audit = AuditService(session)

    @staticmethod
    def evaluate_voter_review_flags(voter: Voter) -> list[str]:
        """Examine voter record for extraction anomalies and flag reasons."""
        flags: list[str] = []

        # Missing EPIC
        epic = (voter.epic_number or "").strip()
        if not epic or epic.upper() in ("UNKNOWN", "MISSING", "NONE", "") or len(epic) < 4:
            flags.append("MISSING_EPIC")

        # Missing relative name
        rel = (voter.relative_name or "").strip()
        if not rel or rel.upper() in ("UNKNOWN", "NONE"):
            flags.append("MISSING_RELATIVE")

        # Missing house number
        house = (voter.house_number or "").strip()
        if not house or house in ("0", "-"):
            flags.append("MISSING_HOUSE")

        # Missing or invalid age
        if not voter.age or voter.age < 18 or voter.age > 125:
            flags.append("INVALID_AGE")

        # Missing gender
        g = (voter.gender or "").strip().upper()
        if not g or g in ("UNKNOWN", "U"):
            flags.append("MISSING_GENDER")

        # Low OCR confidence
        if voter.ocr_confidence is not None and voter.ocr_confidence < 0.60:
            flags.append("LOW_OCR_CONFIDENCE")

        # Parser warnings in raw_data
        if voter.raw_data and "WARNING" in voter.raw_data.upper():
            flags.append("PARSER_WARNING")

        return flags

    def auto_flag_roll_anomalies(self, roll_version_id: str) -> int:
        """Scan all voters in a roll and auto-flag records with extraction issues."""
        voters = self.session.execute(
            select(Voter).where(Voter.roll_version_id == roll_version_id)
        ).scalars().all()

        flagged_count = 0
        for v in voters:
            flags = self.evaluate_voter_review_flags(v)
            if flags:
                reasons_str = ",".join(flags)
                self.field_repo.update_field_information(
                    voter_id=v.id,
                    review_status=ReviewStatusType.NEEDS_REVIEW,
                    review_reasons=reasons_str,
                    reported_by="system_auto_detector",
                )
                flagged_count += 1

        self.session.flush()
        return flagged_count

    def get_review_queue(
        self,
        roll_version_id: str,
        review_status: ReviewStatusType = ReviewStatusType.NEEDS_REVIEW,
        page: int = 1,
        page_size: int = 50,
        context: Optional[SecurityContext] = None,
    ) -> VoterListResponse:
        """Retrieve paginated list of voters requiring manual review."""
        if context:
            context.require_permission(Permission.VIEW_VOTERS)

        offset = (page - 1) * page_size
        voters = self.voter_repo.search_voters(
            roll_version_id=roll_version_id,
            review_status=review_status,
            limit=page_size,
            offset=offset,
        )
        total_count = self.voter_repo.count_voters(
            roll_version_id=roll_version_id,
            review_status=review_status,
        )

        total_pages = max(1, (total_count + page_size - 1) // page_size)
        items = [
            VoterSearchResult(
                voter_id=v.id,
                serial_number=v.serial_number,
                epic_number=v.epic_number,
                name=v.name,
                relative_name=v.relative_name,
                relative_type=v.relative_type,
                house_number=v.house_number,
                age=v.age,
                gender=v.gender,
                part_number=v.part_number,
                polling_station_name=v.polling_station_name,
                photo_path=v.photo_path,
                photo_available=bool(v.photo_path),
                field_status=v.field_status.status.value if v.field_status else "NO_ISSUE",
                review_status=v.field_status.review_status.value if v.field_status else "NOT_REVIEWED",
                phone_number=v.field_status.phone_number if v.field_status else None,
            )
            for v in voters
        ]

        return VoterListResponse(
            items=items,
            total_count=total_count,
            page=page,
            page_size=page_size,
            total_pages=total_pages,
            has_next=page < total_pages,
            has_prev=page > 1,
        )

    def mark_as_reviewed(
        self,
        voter_id: str,
        notes: Optional[str] = None,
        context: Optional[SecurityContext] = None,
    ) -> None:
        """Mark a flagged voter as REVIEWED with an audit record.
        
        Requires REVIEW_RECORDS permission.
        """
        if context:
            context.require_permission(Permission.REVIEW_RECORDS)

        reviewer = context.username if context else "supervisor"
        self.field_repo.update_field_information(
            voter_id=voter_id,
            review_status=ReviewStatusType.REVIEWED,
            notes=notes,
            reported_by=reviewer,
        )

        self.audit.log(
            action="VOTER_REVIEWED",
            entity_type="VOTER_FIELD",
            entity_id=voter_id,
            performed_by=reviewer,
            details={"voter_id": voter_id, "notes": notes},
        )
