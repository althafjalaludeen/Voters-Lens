"""Electoral Roll Version management and Differential Comparison service."""

from typing import Optional, Sequence
from sqlalchemy import select
from sqlalchemy.orm import Session

from voterlens.database.models import RollVersion, RollVersionStatus, Voter
from voterlens.database.repository import ElectoralAreaRepository, ElectoralRollRepository
from voterlens.dto.roll_dto import (
    ElectoralAreaConfigDTO,
    RollComparisonReport,
    RollVersionDTO,
    VoterDifference,
)
from voterlens.services.audit_service import AuditService
from voterlens.services.security import Permission, SecurityContext


class RollService:
    """Manages roll lifecycle invariants, area configurations, and roll comparisons."""

    def __init__(self, session: Session):
        self.session = session
        self.roll_repo = ElectoralRollRepository(session)
        self.area_repo = ElectoralAreaRepository(session)
        self.audit = AuditService(session)

    def setup_electoral_area(
        self,
        state: str,
        district: str,
        assembly_constituency: str,
        selected_part_number: Optional[str] = None,
        context: Optional[SecurityContext] = None,
    ) -> ElectoralAreaConfigDTO:
        """Establish or update local constituency area setup (Admin only)."""
        if context:
            context.require_permission(Permission.MANAGE_ROLLS)

        cfg = self.area_repo.set_config(
            state=state,
            district=district,
            assembly_constituency=assembly_constituency,
            selected_part_number=selected_part_number,
        )
        self.audit.log(
            action="ELECTORAL_AREA_CONFIGURED",
            entity_type="ELECTORAL_AREA",
            entity_id=cfg.id,
            performed_by=context.username if context else "system",
            details={
                "state": state,
                "district": district,
                "assembly_constituency": assembly_constituency,
                "selected_part": selected_part_number,
            },
        )
        return ElectoralAreaConfigDTO(
            id=cfg.id,
            state=cfg.state,
            district=cfg.district,
            assembly_constituency=cfg.assembly_constituency,
            selected_part_number=cfg.selected_part_number,
            active_roll_id=cfg.active_roll_id,
        )

    def get_current_area_config(self) -> Optional[ElectoralAreaConfigDTO]:
        """Fetch the active local electoral area configuration."""
        cfg = self.area_repo.get_current_config()
        if not cfg:
            return None
        return ElectoralAreaConfigDTO(
            id=cfg.id,
            state=cfg.state,
            district=cfg.district,
            assembly_constituency=cfg.assembly_constituency,
            selected_part_number=cfg.selected_part_number,
            active_roll_id=cfg.active_roll_id,
        )

    def get_active_roll(
        self,
        state: Optional[str] = None,
        district: Optional[str] = None,
        assembly_constituency: Optional[str] = None,
    ) -> Optional[RollVersionDTO]:
        """Fetch current active roll version for configured or specified area."""
        if not (state and district and assembly_constituency):
            cfg = self.area_repo.get_current_config()
            if not cfg:
                # Fallback: search for any active roll version
                stmt = select(RollVersion).where(RollVersion.status == RollVersionStatus.ACTIVE)
                roll = self.session.execute(stmt).scalars().first()
                return self._to_dto(roll) if roll else None
            state = cfg.state
            district = cfg.district
            assembly_constituency = cfg.assembly_constituency

        roll = self.roll_repo.get_active_roll(state, district, assembly_constituency)
        return self._to_dto(roll) if roll else None

    def list_rolls_for_area(
        self, state: str, district: str, assembly_constituency: str
    ) -> list[RollVersionDTO]:
        """List all rolls (active, archived, failed) for an area."""
        rolls = self.roll_repo.list_rolls_for_area(state, district, assembly_constituency)
        return [self._to_dto(r) for r in rolls]

    def activate_roll(
        self, roll_id: str, context: Optional[SecurityContext] = None
    ) -> RollVersionDTO:
        """Promote an imported roll to ACTIVE status.
        
        Rules:
        - Incomplete roll with zero records cannot be activated.
        - Previous active roll is automatically archived.
        - Requires ACTIVATE_ROLL permission.
        """
        if context:
            context.require_permission(Permission.ACTIVATE_ROLL)

        roll = self.roll_repo.get_roll_by_id(roll_id)
        if not roll:
            raise ValueError(f"Roll '{roll_id}' not found.")

        if (roll.record_count or 0) <= 0:
            raise ValueError(f"Cannot activate incomplete roll '{roll_id}' with zero records.")

        if roll.status == RollVersionStatus.FAILED:
            raise ValueError(f"Cannot activate failed roll '{roll_id}'.")

        activated = self.roll_repo.activate_roll(roll_id, allow_empty=False)
        self.audit.log(
            action="ROLL_ACTIVATED",
            entity_type="ROLL_VERSION",
            entity_id=activated.id,
            performed_by=context.username if context else "system",
            details={
                "roll_name": activated.roll_name,
                "record_count": activated.record_count,
                "area": f"{activated.state}/{activated.district}/{activated.assembly_constituency}",
            },
        )
        return self._to_dto(activated)

    def compare_rolls(
        self,
        old_roll_id: str,
        new_roll_id: str,
        context: Optional[SecurityContext] = None,
    ) -> RollComparisonReport:
        """Compare two roll versions to audit additions, removals, and record alterations."""
        if context:
            context.require_permission(Permission.VIEW_VOTERS)

        old_roll = self.roll_repo.get_roll_by_id(old_roll_id)
        new_roll = self.roll_repo.get_roll_by_id(new_roll_id)
        if not old_roll or not new_roll:
            raise ValueError("Both old_roll_id and new_roll_id must exist for comparison.")

        # Load voters map by epic
        old_voters = {
            v.epic_number: v
            for v in self.session.execute(
                select(Voter).where(Voter.roll_version_id == old_roll_id)
            ).scalars().all()
        }
        new_voters = {
            v.epic_number: v
            for v in self.session.execute(
                select(Voter).where(Voter.roll_version_id == new_roll_id)
            ).scalars().all()
        }

        added: list[VoterDifference] = []
        removed: list[VoterDifference] = []
        modified: list[VoterDifference] = []
        unchanged_count = 0
        part_changes_count = 0
        station_changes_count = 0

        # Check additions & modifications
        for epic, n_v in new_voters.items():
            if epic not in old_voters:
                added.append(
                    VoterDifference(
                        epic_number=epic,
                        diff_type="ADDED",
                        changes=["New voter card added"],
                        new_data={"name": n_v.name, "house": n_v.house_number, "part": n_v.part_number},
                    )
                )
            else:
                o_v = old_voters[epic]
                changes = []
                if o_v.name != n_v.name:
                    changes.append(f"Name changed: '{o_v.name}' -> '{n_v.name}'")
                if o_v.relative_name != n_v.relative_name:
                    changes.append(f"Relative name changed: '{o_v.relative_name}' -> '{n_v.relative_name}'")
                if o_v.house_number != n_v.house_number:
                    changes.append(f"House number changed: '{o_v.house_number}' -> '{n_v.house_number}'")
                if o_v.age != n_v.age:
                    changes.append(f"Age changed: {o_v.age} -> {n_v.age}")
                if o_v.gender != n_v.gender:
                    changes.append(f"Gender changed: '{o_v.gender}' -> '{n_v.gender}'")
                if o_v.part_number != n_v.part_number:
                    changes.append(f"Part number changed: '{o_v.part_number}' -> '{n_v.part_number}'")
                    part_changes_count += 1
                if o_v.polling_station_name != n_v.polling_station_name:
                    changes.append(f"Polling station changed: '{o_v.polling_station_name}' -> '{n_v.polling_station_name}'")
                    station_changes_count += 1

                if changes:
                    modified.append(
                        VoterDifference(
                            epic_number=epic,
                            diff_type="MODIFIED",
                            changes=changes,
                            old_data={"name": o_v.name, "house": o_v.house_number, "part": o_v.part_number},
                            new_data={"name": n_v.name, "house": n_v.house_number, "part": n_v.part_number},
                        )
                    )
                else:
                    unchanged_count += 1

        # Check removals
        for epic, o_v in old_voters.items():
            if epic not in new_voters:
                removed.append(
                    VoterDifference(
                        epic_number=epic,
                        diff_type="REMOVED",
                        changes=["Voter card removed from new roll"],
                        old_data={"name": o_v.name, "house": o_v.house_number, "part": o_v.part_number},
                    )
                )

        summary = (
            f"Comparison between '{old_roll.roll_name}' and '{new_roll.roll_name}': "
            f"+{len(added)} added, -{len(removed)} removed, ~{len(modified)} modified, "
            f"={unchanged_count} unchanged. {part_changes_count} part transfers, "
            f"{station_changes_count} polling station reassignments."
        )

        return RollComparisonReport(
            old_roll_id=old_roll_id,
            new_roll_id=new_roll_id,
            added_count=len(added),
            removed_count=len(removed),
            modified_count=len(modified),
            unchanged_count=unchanged_count,
            part_changes_count=part_changes_count,
            polling_station_changes_count=station_changes_count,
            differences=added + removed + modified,
            summary=summary,
        )

    def _to_dto(self, roll: RollVersion) -> RollVersionDTO:
        return RollVersionDTO(
            id=roll.id,
            state=roll.state,
            district=roll.district,
            assembly_constituency=roll.assembly_constituency,
            roll_name=roll.roll_name,
            roll_type=roll.roll_type,
            publication_date=roll.publication_date,
            source_reference=roll.source_reference,
            imported_at=roll.imported_at,
            record_count=roll.record_count,
            status=roll.status.value,
            checksum_hash=roll.checksum_hash,
        )
