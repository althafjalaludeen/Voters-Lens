"""Repository layer enforcing dataset immutability and separating official vs field data."""

from datetime import datetime, timezone
import json
from typing import Any, Optional, Sequence

from sqlalchemy import and_, func, or_, select, update, desc, asc
from sqlalchemy.orm import Session, joinedload

from voterlens.database.models import (
    AuditLog,
    ElectoralAreaConfig,
    FieldStatus,
    FieldStatusHistory,
    FieldStatusType,
    ImportReportRecord,
    ReviewStatusType,
    RollVersion,
    RollVersionStatus,
    User,
    UserRole,
    Voter,
    generate_uuid,
    utc_now,
)
from voterlens.database.fts import search_fts_voter_ids


class ImmutableElectoralRollError(Exception):
    """Raised when an attempt is made to mutate or delete official electoral roll data."""
    pass


class ElectoralRollRepository:
    """Manages RollVersion lifecycles and activation invariants."""

    def __init__(self, session: Session):
        self.session = session

    def create_roll_version(
        self,
        state: str,
        district: str,
        assembly_constituency: str,
        roll_name: str,
        roll_type: str = "GENERAL",
        publication_date: Optional[str] = None,
        source_reference: Optional[str] = None,
        checksum_hash: Optional[str] = None,
    ) -> RollVersion:
        """Create a new roll version in IMPORTING state."""
        roll = RollVersion(
            state=state.strip(),
            district=district.strip(),
            assembly_constituency=assembly_constituency.strip(),
            roll_name=roll_name.strip(),
            roll_type=roll_type.strip(),
            publication_date=publication_date,
            source_reference=source_reference,
            status=RollVersionStatus.IMPORTING,
            checksum_hash=checksum_hash,
        )
        self.session.add(roll)
        self.session.flush()
        return roll

    def get_roll_by_id(self, roll_id: str) -> Optional[RollVersion]:
        """Fetch roll version by primary key."""
        return self.session.get(RollVersion, roll_id)

    def get_active_roll(
        self, state: str, district: str, assembly_constituency: str
    ) -> Optional[RollVersion]:
        """Fetch the currently active roll version for an area."""
        stmt = (
            select(RollVersion)
            .where(
                RollVersion.state == state.strip(),
                RollVersion.district == district.strip(),
                RollVersion.assembly_constituency == assembly_constituency.strip(),
                RollVersion.status == RollVersionStatus.ACTIVE,
            )
            .order_by(RollVersion.imported_at.desc())
        )
        return self.session.execute(stmt).scalars().first()

    def activate_roll(self, roll_id: str, allow_empty: bool = True) -> RollVersion:
        """Promote an imported roll to ACTIVE status.
        
        Guarantees that:
        1. Incomplete or failed imports cannot become ACTIVE (when allow_empty=False).
        2. Any existing ACTIVE roll for the area becomes ARCHIVED (never deleted).
        3. The specified roll transitions to ACTIVE and becomes LOCKED.
        """
        roll = self.get_roll_by_id(roll_id)
        if not roll:
            raise ValueError(f"RollVersion '{roll_id}' not found.")

        if roll.status == RollVersionStatus.FAILED:
            raise ValueError(f"Cannot activate failed roll '{roll_id}'.")

        # Incomplete roll check: must have records when allow_empty is False
        if not allow_empty and (roll.record_count or 0) <= 0:
            raise ValueError(f"Cannot activate incomplete roll '{roll_id}' with zero records.")

        # Find any current active roll for the same area and archive it
        existing_active = self.get_active_roll(
            state=roll.state,
            district=roll.district,
            assembly_constituency=roll.assembly_constituency,
        )
        if existing_active and existing_active.id != roll.id:
            existing_active.status = RollVersionStatus.ARCHIVED
            self.session.add(existing_active)

        roll.status = RollVersionStatus.ACTIVE
        self.session.add(roll)

        # Update ElectoralAreaConfig active_roll_id if config exists
        cfg = self.session.execute(
            select(ElectoralAreaConfig).where(
                ElectoralAreaConfig.state == roll.state,
                ElectoralAreaConfig.district == roll.district,
                ElectoralAreaConfig.assembly_constituency == roll.assembly_constituency,
            )
        ).scalars().first()
        if cfg:
            cfg.active_roll_id = roll.id
            self.session.add(cfg)

        self.session.flush()
        return roll

    def mark_roll_failed(self, roll_id: str) -> RollVersion:
        """Mark an import as failed without impacting any active roll."""
        roll = self.get_roll_by_id(roll_id)
        if roll:
            roll.status = RollVersionStatus.FAILED
            self.session.add(roll)
            self.session.flush()
        return roll

    def list_rolls_for_area(
        self, state: str, district: str, assembly_constituency: str
    ) -> Sequence[RollVersion]:
        """List all roll versions (active, archived, failed) for an area."""
        stmt = (
            select(RollVersion)
            .where(
                RollVersion.state == state.strip(),
                RollVersion.district == district.strip(),
                RollVersion.assembly_constituency == assembly_constituency.strip(),
            )
            .order_by(RollVersion.imported_at.desc())
        )
        return self.session.execute(stmt).scalars().all()


class ElectoralAreaRepository:
    """Manages Electoral Area configuration."""

    def __init__(self, session: Session):
        self.session = session

    def get_config(
        self, state: str, district: str, assembly_constituency: str
    ) -> Optional[ElectoralAreaConfig]:
        """Retrieve config for a given area."""
        stmt = select(ElectoralAreaConfig).where(
            ElectoralAreaConfig.state == state.strip(),
            ElectoralAreaConfig.district == district.strip(),
            ElectoralAreaConfig.assembly_constituency == assembly_constituency.strip(),
        )
        return self.session.execute(stmt).scalars().first()

    def get_current_config(self) -> Optional[ElectoralAreaConfig]:
        """Retrieve the primary local area configuration."""
        stmt = select(ElectoralAreaConfig).order_by(ElectoralAreaConfig.created_at.desc())
        return self.session.execute(stmt).scalars().first()

    def set_config(
        self,
        state: str,
        district: str,
        assembly_constituency: str,
        selected_part_number: Optional[str] = None,
        active_roll_id: Optional[str] = None,
    ) -> ElectoralAreaConfig:
        """Create or update electoral area configuration."""
        cfg = self.get_config(state, district, assembly_constituency)
        now = utc_now()
        if cfg:
            cfg.selected_part_number = selected_part_number
            if active_roll_id:
                cfg.active_roll_id = active_roll_id
            cfg.updated_at = now
        else:
            cfg = ElectoralAreaConfig(
                state=state.strip(),
                district=district.strip(),
                assembly_constituency=assembly_constituency.strip(),
                selected_part_number=selected_part_number,
                active_roll_id=active_roll_id,
                created_at=now,
                updated_at=now,
            )
            self.session.add(cfg)
        self.session.flush()
        return cfg


class VoterRepository:
    """Manages voter records, search queries, filtering, and immutability rules."""

    def __init__(self, session: Session):
        self.session = session

    def insert_voters_batch(self, roll_id: str, voter_records: list[dict[str, Any]]) -> int:
        """Batch insert voter records for a roll version currently in IMPORTING status."""
        roll = self.session.get(RollVersion, roll_id)
        if not roll:
            raise ValueError(f"RollVersion '{roll_id}' does not exist.")
        if roll.status != RollVersionStatus.IMPORTING:
            raise ImmutableElectoralRollError(
                f"Cannot insert voters into roll version '{roll_id}' with status '{roll.status}'. "
                "Voters can only be inserted while status is IMPORTING."
            )

        objects = []
        for r in voter_records:
            v_id = r.get("id") or generate_uuid()
            obj = Voter(
                id=v_id,
                roll_version_id=roll_id,
                serial_number=int(r["serial_number"]),
                epic_number=r["epic_number"].strip(),
                name=r["name"].strip(),
                normalized_name=r.get("normalized_name", r["name"].strip()).strip(),
                relative_name=r.get("relative_name", "").strip(),
                normalized_relative_name=r.get(
                    "normalized_relative_name", r.get("relative_name", "").strip()
                ).strip(),
                relative_type=r.get("relative_type", "OTHER").strip(),
                house_number=str(r.get("house_number", "")).strip(),
                normalized_house_number=str(
                    r.get("normalized_house_number", r.get("house_number", ""))
                ).strip(),
                age=int(r["age"]),
                gender=r["gender"].strip(),
                part_number=str(r.get("part_number", "")).strip(),
                section_number=str(r.get("section_number", "")).strip(),
                section_name=str(r.get("section_name", "")).strip(),
                polling_station_name=str(r.get("polling_station_name", "")).strip(),
                polling_station_address=str(r.get("polling_station_address", "")).strip(),
                photo_path=r.get("photo_path"),
                ocr_confidence=r.get("ocr_confidence"),
                raw_data=r.get("raw_data"),
            )
            objects.append(obj)

        self.session.bulk_save_objects(objects)
        roll.record_count = (roll.record_count or 0) + len(objects)
        self.session.flush()
        return len(objects)

    def get_voter_by_id(self, voter_id: str) -> Optional[Voter]:
        """Fetch voter with associated field status."""
        stmt = (
            select(Voter)
            .options(joinedload(Voter.field_status))
            .where(Voter.id == voter_id)
        )
        return self.session.execute(stmt).scalars().first()

    def get_voter_by_epic(self, epic_number: str, roll_version_id: Optional[str] = None) -> Sequence[Voter]:
        """Fetch voter(s) by EPIC number."""
        stmt = (
            select(Voter)
            .options(joinedload(Voter.field_status))
            .where(Voter.epic_number == epic_number.strip().upper())
        )
        if roll_version_id:
            stmt = stmt.where(Voter.roll_version_id == roll_version_id)
        return self.session.execute(stmt).scalars().all()

    def _build_search_query(
        self,
        roll_version_id: str,
        query: Optional[str] = None,
        name: Optional[str] = None,
        epic: Optional[str] = None,
        house_number: Optional[str] = None,
        relative_name: Optional[str] = None,
        part_number: Optional[str] = None,
        serial_number: Optional[int] = None,
        section_number: Optional[str] = None,
        polling_station_name: Optional[str] = None,
        gender: Optional[str] = None,
        field_status: Optional[FieldStatusType] = None,
        review_status: Optional[ReviewStatusType] = None,
        phone_number: Optional[str] = None,
        use_fts: bool = False,
    ):
        """Construct SQLAlchemy query with all active filters combined."""
        stmt = (
            select(Voter)
            .options(joinedload(Voter.field_status))
            .where(Voter.roll_version_id == roll_version_id)
        )

        # FTS5 search optimization if requested and query term is provided
        if use_fts and query:
            matching_ids = search_fts_voter_ids(self.session, roll_version_id, query)
            if matching_ids:
                stmt = stmt.where(Voter.id.in_(matching_ids))
            else:
                # FTS didn't find results or empty; fallback to LIKE
                q_clean = query.strip()
                q_like = f"%{q_clean}%"
                stmt = stmt.where(
                    or_(
                        Voter.name.ilike(q_like),
                        Voter.normalized_name.ilike(q_like),
                        Voter.epic_number.ilike(q_like),
                        Voter.relative_name.ilike(q_like),
                        Voter.house_number.ilike(q_like),
                    )
                )
        elif query:
            q_clean = query.strip()
            q_like = f"%{q_clean}%"
            stmt = stmt.where(
                or_(
                    Voter.name.ilike(q_like),
                    Voter.normalized_name.ilike(q_like),
                    Voter.epic_number.ilike(q_like),
                    Voter.relative_name.ilike(q_like),
                    Voter.house_number.ilike(q_like),
                )
            )

        if name:
            n_like = f"%{name.strip()}%"
            stmt = stmt.where(
                or_(Voter.name.ilike(n_like), Voter.normalized_name.ilike(n_like))
            )

        if epic:
            stmt = stmt.where(Voter.epic_number.ilike(f"%{epic.strip()}%"))

        if house_number:
            stmt = stmt.where(
                or_(
                    Voter.house_number.ilike(f"%{house_number.strip()}%"),
                    Voter.normalized_house_number.ilike(f"%{house_number.strip()}%"),
                )
            )

        if relative_name:
            r_like = f"%{relative_name.strip()}%"
            stmt = stmt.where(
                or_(Voter.relative_name.ilike(r_like), Voter.normalized_relative_name.ilike(r_like))
            )

        if part_number:
            stmt = stmt.where(Voter.part_number == str(part_number).strip())

        if serial_number is not None:
            stmt = stmt.where(Voter.serial_number == int(serial_number))

        if section_number:
            stmt = stmt.where(Voter.section_number == str(section_number).strip())

        if polling_station_name:
            stmt = stmt.where(Voter.polling_station_name.ilike(f"%{polling_station_name.strip()}%"))

        if gender and gender.upper() != "ALL":
            g_val = gender.strip().upper()
            if g_val in ("M", "MALE"):
                stmt = stmt.where(Voter.gender.in_(["M", "Male", "പുരുഷൻ"]))
            elif g_val in ("F", "FEMALE"):
                stmt = stmt.where(Voter.gender.in_(["F", "Female", "സ്ത്രീ"]))
            else:
                stmt = stmt.where(Voter.gender.ilike(gender.strip()))

        # Join field_status if needed for filtering
        needs_field_join = (
            field_status is not None 
            or (review_status is not None and review_status.value != "ALL") 
            or bool(phone_number)
        )
        if needs_field_join:
            stmt = stmt.outerjoin(Voter.field_status)

        if field_status:
            if field_status == FieldStatusType.NO_ISSUE:
                stmt = stmt.where(
                    or_(
                        FieldStatus.status == FieldStatusType.NO_ISSUE,
                        FieldStatus.id.is_(None),
                    )
                )
            else:
                stmt = stmt.where(FieldStatus.status == field_status)

        if review_status and review_status.value != "ALL":
            if review_status == ReviewStatusType.NOT_REVIEWED:
                stmt = stmt.where(
                    or_(
                        FieldStatus.review_status == ReviewStatusType.NOT_REVIEWED,
                        FieldStatus.id.is_(None),
                    )
                )
            else:
                stmt = stmt.where(FieldStatus.review_status == review_status)

        if phone_number:
            stmt = stmt.where(FieldStatus.phone_number.ilike(f"%{phone_number.strip()}%"))

        return stmt

    def search_voters(
        self,
        roll_version_id: str,
        query: Optional[str] = None,
        name: Optional[str] = None,
        epic: Optional[str] = None,
        house_number: Optional[str] = None,
        relative_name: Optional[str] = None,
        part_number: Optional[str] = None,
        serial_number: Optional[int] = None,
        section_number: Optional[str] = None,
        polling_station_name: Optional[str] = None,
        gender: Optional[str] = None,
        field_status: Optional[FieldStatusType] = None,
        review_status: Optional[ReviewStatusType] = None,
        phone_number: Optional[str] = None,
        sort_by: str = "serial_number",
        sort_order: str = "asc",
        use_fts: bool = False,
        limit: int = 50,
        offset: int = 0,
    ) -> Sequence[Voter]:
        """Search and filter voters with multi-criteria support, sorting, and pagination."""
        stmt = self._build_search_query(
            roll_version_id=roll_version_id,
            query=query,
            name=name,
            epic=epic,
            house_number=house_number,
            relative_name=relative_name,
            part_number=part_number,
            serial_number=serial_number,
            section_number=section_number,
            polling_station_name=polling_station_name,
            gender=gender,
            field_status=field_status,
            review_status=review_status,
            phone_number=phone_number,
            use_fts=use_fts,
        )

        # Apply sorting
        order_col = Voter.serial_number
        if sort_by == "name":
            order_col = Voter.name
        elif sort_by == "house_number":
            order_col = Voter.normalized_house_number
        elif sort_by == "age":
            order_col = Voter.age
        elif sort_by == "part_number":
            order_col = Voter.part_number
        elif sort_by == "field_status":
            stmt = stmt.outerjoin(Voter.field_status)
            order_col = FieldStatus.status
        elif sort_by == "review_status":
            stmt = stmt.outerjoin(Voter.field_status)
            order_col = FieldStatus.review_status

        direction = desc if sort_order.lower() == "desc" else asc
        stmt = stmt.order_by(Voter.part_number, direction(order_col), Voter.serial_number)
        stmt = stmt.limit(limit).offset(offset)

        return self.session.execute(stmt).scalars().all()

    def count_voters(
        self,
        roll_version_id: str,
        query: Optional[str] = None,
        name: Optional[str] = None,
        epic: Optional[str] = None,
        house_number: Optional[str] = None,
        relative_name: Optional[str] = None,
        part_number: Optional[str] = None,
        serial_number: Optional[int] = None,
        section_number: Optional[str] = None,
        polling_station_name: Optional[str] = None,
        gender: Optional[str] = None,
        field_status: Optional[FieldStatusType] = None,
        review_status: Optional[ReviewStatusType] = None,
        phone_number: Optional[str] = None,
        use_fts: bool = False,
    ) -> int:
        """Count total matching records for pagination calculation."""
        base_stmt = self._build_search_query(
            roll_version_id=roll_version_id,
            query=query,
            name=name,
            epic=epic,
            house_number=house_number,
            relative_name=relative_name,
            part_number=part_number,
            serial_number=serial_number,
            section_number=section_number,
            polling_station_name=polling_station_name,
            gender=gender,
            field_status=field_status,
            review_status=review_status,
            phone_number=phone_number,
            use_fts=use_fts,
        )
        count_stmt = select(func.count()).select_from(base_stmt.subquery())
        return self.session.execute(count_stmt).scalar() or 0

    def get_household_groups(
        self,
        roll_version_id: str,
        part_number: Optional[str] = None,
        limit: int = 50,
        offset: int = 0,
    ) -> tuple[list[dict[str, Any]], int]:
        """Group voters by normalized house number while preserving original house number."""
        # Query distinct normalized house numbers ordered by count / serial
        stmt = (
            select(
                Voter.normalized_house_number,
                func.min(Voter.house_number).label("original_house"),
                func.count(Voter.id).label("voter_count"),
            )
            .where(
                Voter.roll_version_id == roll_version_id,
                Voter.normalized_house_number != "",
            )
        )
        if part_number:
            stmt = stmt.where(Voter.part_number == str(part_number).strip())

        stmt = stmt.group_by(Voter.normalized_house_number).order_by(
            func.min(Voter.part_number), func.min(Voter.serial_number)
        )

        total_houses = self.session.execute(
            select(func.count()).select_from(stmt.subquery())
        ).scalar() or 0

        paged_houses = self.session.execute(stmt.limit(limit).offset(offset)).all()

        groups = []
        for norm_h, orig_h, count in paged_houses:
            # Fetch voters in this house
            v_stmt = (
                select(Voter)
                .options(joinedload(Voter.field_status))
                .where(
                    Voter.roll_version_id == roll_version_id,
                    Voter.normalized_house_number == norm_h,
                )
            )
            if part_number:
                v_stmt = v_stmt.where(Voter.part_number == str(part_number).strip())
            v_stmt = v_stmt.order_by(Voter.serial_number)
            voters = self.session.execute(v_stmt).scalars().all()

            groups.append({
                "house_number": orig_h,
                "normalized_house_number": norm_h,
                "voter_count": count,
                "voters": voters,
            })

        return groups, total_houses

    def get_area_statistics(
        self, roll_version_id: str, part_number: Optional[str] = None
    ) -> dict[str, Any]:
        """Aggregate electoral part statistics: total, status counts, gender counts."""
        base_where = [Voter.roll_version_id == roll_version_id]
        if part_number:
            base_where.append(Voter.part_number == str(part_number).strip())

        # Total voters
        total_voters = self.session.execute(
            select(func.count(Voter.id)).where(and_(*base_where))
        ).scalar() or 0

        # Gender breakdown
        gender_rows = self.session.execute(
            select(Voter.gender, func.count(Voter.id))
            .where(and_(*base_where))
            .group_by(Voter.gender)
        ).all()
        gender_counts = {str(row[0]): int(row[1]) for row in gender_rows}

        # Field status breakdown
        status_stmt = (
            select(
                func.coalesce(FieldStatus.status, FieldStatusType.NO_ISSUE).label("st"),
                func.count(Voter.id),
            )
            .outerjoin(Voter.field_status)
            .where(and_(*base_where))
            .group_by("st")
        )
        status_rows = self.session.execute(status_stmt).all()
        field_status_counts = {
            (row[0].value if hasattr(row[0], "value") else str(row[0])): int(row[1])
            for row in status_rows
        }
        for st in FieldStatusType:
            if st.value not in field_status_counts:
                field_status_counts[st.value] = 0

        # Review status breakdown
        rev_stmt = (
            select(
                func.coalesce(FieldStatus.review_status, ReviewStatusType.NOT_REVIEWED).label("rst"),
                func.count(Voter.id),
            )
            .outerjoin(Voter.field_status)
            .where(and_(*base_where))
            .group_by("rst")
        )
        rev_rows = self.session.execute(rev_stmt).all()
        review_status_counts = {
            (row[0].value if hasattr(row[0], "value") else str(row[0])): int(row[1])
            for row in rev_rows
        }
        for rst in ReviewStatusType:
            if rst.value not in review_status_counts:
                review_status_counts[rst.value] = 0

        return {
            "total_voters": total_voters,
            "gender_counts": gender_counts,
            "field_status_counts": field_status_counts,
            "review_status_counts": review_status_counts,
            "part_number": part_number,
        }

    def get_hierarchy(self, roll_version_id: str) -> list[dict[str, Any]]:
        """Retrieve hierarchy: Part -> Section -> Polling Station."""
        stmt = (
            select(
                Voter.part_number,
                Voter.section_number,
                Voter.section_name,
                Voter.polling_station_name,
                Voter.polling_station_address,
                func.count(Voter.id).label("voter_count"),
            )
            .where(Voter.roll_version_id == roll_version_id)
            .group_by(
                Voter.part_number,
                Voter.section_number,
                Voter.section_name,
                Voter.polling_station_name,
                Voter.polling_station_address,
            )
            .order_by(Voter.part_number, Voter.section_number)
        )
        rows = self.session.execute(stmt).all()
        return [
            {
                "part_number": r[0],
                "section_number": r[1],
                "section_name": r[2],
                "polling_station_name": r[3],
                "polling_station_address": r[4],
                "voter_count": r[5],
            }
            for row in rows
        ]

    def update_voter_disallowed(self, voter_id: str, *args, **kwargs) -> None:
        """Enforce strict immutability rule: official voter details cannot be edited."""
        raise ImmutableElectoralRollError(
            f"Electoral roll data is strictly immutable. Voter {voter_id} cannot be modified. "
            "To record field observations (e.g. deceased, moved, away), update field_status instead."
        )

    def delete_voter_disallowed(self, voter_id: str) -> None:
        """Enforce strict immutability rule: official voter details cannot be deleted."""
        raise ImmutableElectoralRollError(
            f"Electoral roll data is strictly immutable. Voter {voter_id} cannot be deleted. "
            "To record field observations (e.g. deceased), update field_status instead."
        )


class FieldStatusRepository:
    """Manages field verification observations and complete audit trail.
    
    CRITICAL: Field status changes NEVER alter the official Voter record.
    Even 'REPORTED_DECEASED' is an audited observation, leaving the voter intact.
    """

    def __init__(self, session: Session):
        self.session = session

    def get_status(self, voter_id: str) -> FieldStatusType:
        """Get the current field status of a voter (defaults to NO_ISSUE)."""
        record = self.session.execute(
            select(FieldStatus).where(FieldStatus.voter_id == voter_id)
        ).scalars().first()
        return record.status if record else FieldStatusType.NO_ISSUE

    def get_field_status_record(self, voter_id: str) -> Optional[FieldStatus]:
        """Fetch the full FieldStatus record including phone and review fields."""
        return self.session.execute(
            select(FieldStatus).where(FieldStatus.voter_id == voter_id)
        ).scalars().first()

    def set_status(
        self,
        voter_id: str,
        new_status: FieldStatusType,
        notes: Optional[str] = None,
        reported_by: Optional[str] = None,
    ) -> FieldStatus:
        """Record or update a field status observation.
        
        Guarantees:
        1. An audit record is created in field_status_history.
        2. The official voter record remains completely unchanged.
        """
        # Verify the voter exists
        voter = self.session.get(Voter, voter_id)
        if not voter:
            raise ValueError(f"Voter '{voter_id}' does not exist.")

        now = utc_now()
        existing = self.session.execute(
            select(FieldStatus).where(FieldStatus.voter_id == voter_id)
        ).scalars().first()

        old_status_val = existing.status.value if existing else FieldStatusType.NO_ISSUE.value

        if existing:
            existing.status = new_status
            existing.notes = notes
            existing.reported_by = reported_by
            existing.updated_at = now
            field_record = existing
        else:
            field_record = FieldStatus(
                voter_id=voter_id,
                status=new_status,
                notes=notes,
                reported_by=reported_by,
                reported_at=now,
                updated_at=now,
            )
            self.session.add(field_record)

        # Append to audit history
        history_entry = FieldStatusHistory(
            voter_id=voter_id,
            old_status=old_status_val,
            new_status=new_status.value,
            notes=notes,
            changed_by=reported_by,
            changed_at=now,
        )
        self.session.add(history_entry)
        self.session.flush()
        return field_record

    def update_field_information(
        self,
        voter_id: str,
        phone_number: Optional[str] = None,
        notes: Optional[str] = None,
        status: Optional[FieldStatusType] = None,
        review_status: Optional[ReviewStatusType] = None,
        review_reasons: Optional[str] = None,
        reported_by: Optional[str] = None,
    ) -> FieldStatus:
        """Update any editable local field information with audit tracking."""
        voter = self.session.get(Voter, voter_id)
        if not voter:
            raise ValueError(f"Voter '{voter_id}' does not exist.")

        now = utc_now()
        existing = self.session.execute(
            select(FieldStatus).where(FieldStatus.voter_id == voter_id)
        ).scalars().first()

        old_status_val = existing.status.value if existing else FieldStatusType.NO_ISSUE.value

        if existing:
            if status is not None:
                existing.status = status
            if phone_number is not None:
                existing.phone_number = phone_number
            if notes is not None:
                existing.notes = notes
            if review_status is not None:
                existing.review_status = review_status
                if review_status == ReviewStatusType.REVIEWED:
                    existing.reviewed_by = reported_by
                    existing.reviewed_at = now
            if review_reasons is not None:
                existing.review_reasons = review_reasons
            existing.reported_by = reported_by
            existing.updated_at = now
            field_record = existing
        else:
            field_record = FieldStatus(
                voter_id=voter_id,
                status=status or FieldStatusType.NO_ISSUE,
                phone_number=phone_number,
                notes=notes,
                review_status=review_status or ReviewStatusType.NOT_REVIEWED,
                review_reasons=review_reasons,
                reviewed_by=reported_by if review_status == ReviewStatusType.REVIEWED else None,
                reviewed_at=now if review_status == ReviewStatusType.REVIEWED else None,
                reported_by=reported_by,
                reported_at=now,
                updated_at=now,
            )
            self.session.add(field_record)

        # If status changed, record history
        new_status_val = field_record.status.value
        if new_status_val != old_status_val:
            history_entry = FieldStatusHistory(
                voter_id=voter_id,
                old_status=old_status_val,
                new_status=new_status_val,
                notes=notes,
                changed_by=reported_by,
                changed_at=now,
            )
            self.session.add(history_entry)

        self.session.flush()
        return field_record

    def get_history(self, voter_id: str) -> Sequence[FieldStatusHistory]:
        """Fetch complete chronological audit history for a voter."""
        stmt = (
            select(FieldStatusHistory)
            .where(FieldStatusHistory.voter_id == voter_id)
            .order_by(FieldStatusHistory.changed_at.asc())
        )
        return self.session.execute(stmt).scalars().all()


class UserRepository:
    """Manages local users and roles."""

    def __init__(self, session: Session):
        self.session = session

    def create_user(
        self, username: str, full_name: str, role: UserRole = UserRole.VIEWER
    ) -> User:
        user = User(
            username=username.strip().lower(),
            full_name=full_name.strip(),
            role=role,
            is_active=True,
        )
        self.session.add(user)
        self.session.flush()
        return user

    def get_user_by_username(self, username: str) -> Optional[User]:
        stmt = select(User).where(User.username == username.strip().lower())
        return self.session.execute(stmt).scalars().first()

    def get_user_by_id(self, user_id: str) -> Optional[User]:
        return self.session.get(User, user_id)

    def list_users(self) -> Sequence[User]:
        return self.session.execute(select(User).order_by(User.username)).scalars().all()

    def update_role(self, user_id: str, new_role: UserRole) -> User:
        user = self.get_user_by_id(user_id)
        if not user:
            raise ValueError(f"User '{user_id}' not found.")
        user.role = new_role
        user.updated_at = utc_now()
        self.session.flush()
        return user


class AuditRepository:
    """Stores and retrieves system audit logs."""

    def __init__(self, session: Session):
        self.session = session

    def log_event(
        self,
        action: str,
        entity_type: str,
        entity_id: Optional[str] = None,
        performed_by: Optional[str] = None,
        details: Optional[dict[str, Any]] = None,
    ) -> AuditLog:
        """Create an immutable audit entry without sensitive personal voter details."""
        detail_str = json.dumps(details) if details else None
        entry = AuditLog(
            action=action.strip(),
            entity_type=entity_type.strip(),
            entity_id=entity_id,
            performed_by=performed_by,
            details=detail_str,
            timestamp=utc_now(),
        )
        self.session.add(entry)
        self.session.flush()
        return entry

    def get_recent_logs(
        self,
        action: Optional[str] = None,
        entity_type: Optional[str] = None,
        limit: int = 50,
        offset: int = 0,
    ) -> Sequence[AuditLog]:
        stmt = select(AuditLog)
        if action:
            stmt = stmt.where(AuditLog.action == action.strip())
        if entity_type:
            stmt = stmt.where(AuditLog.entity_type == entity_type.strip())
        stmt = stmt.order_by(AuditLog.timestamp.desc()).limit(limit).offset(offset)
        return self.session.execute(stmt).scalars().all()
