"""Unified multi-criteria search engine and filtering service for VoterLens."""

from pathlib import Path
from typing import Optional
from sqlalchemy.orm import Session

from voterlens.database.models import FieldStatusType, ReviewStatusType
from voterlens.database.repository import VoterRepository
from voterlens.dto.filter_dto import FieldStatusFilter, GenderFilter, ReviewStatusFilter, SearchCriteria
from voterlens.dto.voter_dto import FIELD_STATUS_LABELS, VoterListResponse, VoterSearchResult
from voterlens.services.security import Permission, SecurityContext


class SearchService:
    """Unified search and filtering engine supporting exact, prefix, Malayalam Unicode, and FTS5 search."""

    def __init__(self, session: Session):
        self.session = session
        self.voter_repo = VoterRepository(session)

    def search(
        self,
        roll_version_id: str,
        criteria: SearchCriteria,
        context: Optional[SecurityContext] = None,
    ) -> VoterListResponse:
        """Execute multi-criteria search and return paginated DTO results."""
        if context:
            context.require_permission(Permission.SEARCH_VOTERS)

        # Convert enum filters to repository types
        fs_enum = None
        if criteria.field_status and criteria.field_status != FieldStatusFilter.ALL:
            fs_enum = FieldStatusType(criteria.field_status.value)

        rs_enum = None
        if criteria.review_status and criteria.review_status != ReviewStatusFilter.ALL:
            rs_enum = ReviewStatusType(criteria.review_status.value)

        gender_val = criteria.gender.value if criteria.gender else "ALL"

        offset = (criteria.page - 1) * criteria.page_size

        voters = self.voter_repo.search_voters(
            roll_version_id=roll_version_id,
            query=criteria.query,
            name=criteria.name,
            epic=criteria.epic,
            house_number=criteria.house_number,
            relative_name=criteria.relative_name,
            part_number=criteria.part_number,
            serial_number=criteria.serial_number,
            section_number=criteria.section_number,
            polling_station_name=criteria.polling_station_name,
            gender=gender_val,
            field_status=fs_enum,
            review_status=rs_enum,
            phone_number=criteria.phone_number,
            sort_by=criteria.sort.field.value,
            sort_order=criteria.sort.direction.value,
            use_fts=criteria.use_fts,
            limit=criteria.page_size,
            offset=offset,
        )

        total_count = self.voter_repo.count_voters(
            roll_version_id=roll_version_id,
            query=criteria.query,
            name=criteria.name,
            epic=criteria.epic,
            house_number=criteria.house_number,
            relative_name=criteria.relative_name,
            part_number=criteria.part_number,
            serial_number=criteria.serial_number,
            section_number=criteria.section_number,
            polling_station_name=criteria.polling_station_name,
            gender=gender_val,
            field_status=fs_enum,
            review_status=rs_enum,
            phone_number=criteria.phone_number,
            use_fts=criteria.use_fts,
        )

        total_pages = max(1, (total_count + criteria.page_size - 1) // criteria.page_size)

        items = []
        for v in voters:
            fs_val = v.field_status.status.value if v.field_status else "NO_ISSUE"
            rst_val = v.field_status.review_status.value if v.field_status else "NOT_REVIEWED"
            phone = v.field_status.phone_number if v.field_status else None
            photo_exists = bool(v.photo_path and Path(v.photo_path).exists())

            items.append(
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
                    photo_available=photo_exists,
                    field_status=fs_val,
                    field_status_label=FIELD_STATUS_LABELS.get(fs_val, fs_val),
                    review_status=rst_val,
                    phone_number=phone,
                )
            )

        return VoterListResponse(
            items=items,
            total_count=total_count,
            page=criteria.page,
            page_size=criteria.page_size,
            total_pages=total_pages,
            has_next=criteria.page < total_pages,
            has_prev=criteria.page > 1,
        )
