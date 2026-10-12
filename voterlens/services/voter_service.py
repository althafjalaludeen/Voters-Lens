"""Voter service providing voter list, voter detail, household grouping, and statistics."""

from pathlib import Path
from typing import Optional
from sqlalchemy.orm import Session

from voterlens.database.repository import VoterRepository
from voterlens.dto.filter_dto import SearchCriteria, SortOptions
from voterlens.dto.voter_dto import (
    FIELD_STATUS_LABELS,
    AreaStatistics,
    FieldStatusHistoryDTO,
    HouseholdGroup,
    VoterDetail,
    VoterFieldDTO,
    VoterListResponse,
    VoterOfficialDTO,
    VoterSearchResult,
)
from voterlens.services.search_service import SearchService
from voterlens.services.security import Permission, SecurityContext


class VoterService:
    """High-level service interface for voter data retrieval, household views, and statistics."""

    def __init__(self, session: Session):
        self.session = session
        self.voter_repo = VoterRepository(session)
        self.search_service = SearchService(session)

    def get_voters(
        self,
        roll_version_id: str,
        page: int = 1,
        page_size: int = 50,
        part_number: Optional[str] = None,
        sort: Optional[SortOptions] = None,
        context: Optional[SecurityContext] = None,
    ) -> VoterListResponse:
        """Fetch the paginated full voter list, sorted by serial number by default."""
        if context:
            context.require_permission(Permission.VIEW_VOTERS)

        criteria = SearchCriteria(
            part_number=part_number,
            page=page,
            page_size=page_size,
            sort=sort or SortOptions(),
        )
        return self.search_service.search(roll_version_id, criteria, context=context)

    def get_voter(
        self, voter_id: str, context: Optional[SecurityContext] = None
    ) -> Optional[VoterDetail]:
        """Fetch a single voter with clean separation of official and field information."""
        if context:
            context.require_permission(Permission.VIEW_VOTERS)

        voter = self.voter_repo.get_voter_by_id(voter_id)
        if not voter:
            return None

        # Check local photo file existence
        photo_exists = False
        photo_status = "PHOTO_UNAVAILABLE"
        if voter.photo_path:
            p = Path(voter.photo_path)
            if p.exists() and p.is_file():
                photo_exists = True
                photo_status = "PHOTO_AVAILABLE"

        official_dto = VoterOfficialDTO(
            id=voter.id,
            roll_version_id=voter.roll_version_id,
            serial_number=voter.serial_number,
            epic_number=voter.epic_number,
            name=voter.name,
            normalized_name=voter.normalized_name,
            relative_name=voter.relative_name,
            normalized_relative_name=voter.normalized_relative_name,
            relative_type=voter.relative_type,
            house_number=voter.house_number,
            normalized_house_number=voter.normalized_house_number,
            age=voter.age,
            gender=voter.gender,
            part_number=voter.part_number,
            section_number=voter.section_number,
            section_name=voter.section_name,
            polling_station_name=voter.polling_station_name,
            polling_station_address=voter.polling_station_address,
            photo_path=voter.photo_path,
            photo_available=photo_exists,
            photo_status=photo_status,
            ocr_confidence=voter.ocr_confidence,
        )

        history_dtos = [
            FieldStatusHistoryDTO(
                id=h.id,
                voter_id=h.voter_id,
                old_status=h.old_status,
                new_status=h.new_status,
                notes=h.notes,
                changed_by=h.changed_by,
                changed_at=h.changed_at,
            )
            for h in voter.field_status_history
        ]

        if voter.field_status:
            fs = voter.field_status
            status_str = fs.status.value
            reasons = [r.strip() for r in (fs.review_reasons or "").split(",") if r.strip()]
            field_dto = VoterFieldDTO(
                status=status_str,
                status_label=FIELD_STATUS_LABELS.get(status_str, status_str),
                phone_number=fs.phone_number,
                notes=fs.notes,
                review_status=fs.review_status.value,
                review_reasons=reasons,
                reviewed_by=fs.reviewed_by,
                reviewed_at=fs.reviewed_at,
                reported_by=fs.reported_by,
                reported_at=fs.reported_at,
                history=history_dtos,
            )
        else:
            field_dto = VoterFieldDTO(
                status="NO_ISSUE",
                status_label=FIELD_STATUS_LABELS["NO_ISSUE"],
                history=history_dtos,
            )

        return VoterDetail(
            voter_id=voter.id,
            official=official_dto,
            field=field_dto,
        )

    def get_household_groups(
        self,
        roll_version_id: str,
        part_number: Optional[str] = None,
        page: int = 1,
        page_size: int = 50,
        context: Optional[SecurityContext] = None,
    ) -> tuple[list[HouseholdGroup], int]:
        """Query voters grouped by normalized household number."""
        if context:
            context.require_permission(Permission.VIEW_VOTERS)

        offset = (page - 1) * page_size
        raw_groups, total_count = self.voter_repo.get_household_groups(
            roll_version_id=roll_version_id,
            part_number=part_number,
            limit=page_size,
            offset=offset,
        )

        groups = []
        for g in raw_groups:
            v_dtos = [
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
                    photo_available=bool(v.photo_path and Path(v.photo_path).exists()),
                    field_status=v.field_status.status.value if v.field_status else "NO_ISSUE",
                    review_status=v.field_status.review_status.value if v.field_status else "NOT_REVIEWED",
                    phone_number=v.field_status.phone_number if v.field_status else None,
                )
                for v in g["voters"]
            ]
            groups.append(
                HouseholdGroup(
                    house_number=g["house_number"],
                    normalized_house_number=g["normalized_house_number"],
                    voter_count=g["voter_count"],
                    voters=v_dtos,
                )
            )

        return groups, total_count

    def get_area_statistics(
        self,
        roll_version_id: str,
        part_number: Optional[str] = None,
        context: Optional[SecurityContext] = None,
    ) -> AreaStatistics:
        """Fetch database-management metrics: totals, status counts, gender counts."""
        if context:
            context.require_permission(Permission.VIEW_VOTERS)

        stats = self.voter_repo.get_area_statistics(roll_version_id, part_number=part_number)
        return AreaStatistics(
            total_voters=stats["total_voters"],
            part_number=stats["part_number"],
            gender_counts=stats["gender_counts"],
            field_status_counts=stats["field_status_counts"],
            review_status_counts=stats["review_status_counts"],
        )

    def get_voter_photo_bytes(
        self, voter_id: str, context: Optional[SecurityContext] = None
    ) -> Optional[bytes]:
        """Lazy offline image retrieval: reads photo from local disk only, zero network requests."""
        if context:
            context.require_permission(Permission.VIEW_VOTERS)

        voter = self.voter_repo.get_voter_by_id(voter_id)
        if not voter or not voter.photo_path:
            return None

        p = Path(voter.photo_path)
        if p.exists() and p.is_file():
            return p.read_bytes()
        return None
