"""Conflict detection, classification, and reconciliation engine."""

from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

from sqlalchemy import select
from sqlalchemy.orm import Session

from voterlens.database.models import (
    FieldStatus,
    FieldStatusHistory,
    FieldStatusType,
    ReviewStatusType,
    Voter,
    utc_now,
)
from voterlens.services.audit_service import AuditService
from voterlens.services.security import Permission, SecurityContext
from voterlens.sync.models import (
    ConflictResolutionStatus,
    ConflictType,
    FieldObservation,
    SyncConflict,
)


class ConflictAnalysisResult:
    """Outcome of conflict analysis for an incoming observation."""

    def __init__(
        self,
        conflict_type: Optional[ConflictType],
        is_actionable: bool,
        message: str,
        existing_observation: Optional[FieldObservation] = None,
    ):
        self.conflict_type = conflict_type
        self.is_actionable = is_actionable  # True if state should be updated
        self.message = message
        self.existing_observation = existing_observation


class ConflictEngine:
    """Analyzes incoming observations against local state and manages reconciliation."""

    @staticmethod
    def analyze_observation(
        session: Session,
        incoming: Dict[str, any],
        matched_voter: Optional[Voter],
    ) -> ConflictAnalysisResult:
        """Classify an incoming observation and determine if it represents a conflict."""
        obs_id = incoming.get("observation_id")
        epic = incoming.get("voter_epic")

        # 1. Voter existence check
        if matched_voter is None:
            return ConflictAnalysisResult(
                conflict_type=ConflictType.VOTER_NOT_FOUND,
                is_actionable=False,
                message=f"Voter with EPIC {epic} not found in active roll",
            )

        # 2. Check for exact duplicate observation ID (idempotency)
        stmt_dup = select(FieldObservation).where(
            FieldObservation.observation_id == obs_id
        )
        existing_obs = session.execute(stmt_dup).scalars().first()
        if existing_obs:
            return ConflictAnalysisResult(
                conflict_type=ConflictType.DUPLICATE,
                is_actionable=False,
                message=f"Observation {obs_id} already imported",
                existing_observation=existing_obs,
            )

        # 3. Retrieve latest local observation for this voter
        stmt_latest = (
            select(FieldObservation)
            .where(
                FieldObservation.voter_epic == epic,
                FieldObservation.is_revoked == False,
            )
            .order_by(FieldObservation.created_at.desc())
        )
        latest_local_obs = session.execute(stmt_latest).scalars().first()

        # If no prior observations exist locally, no conflict
        if not latest_local_obs:
            return ConflictAnalysisResult(
                conflict_type=None,
                is_actionable=True,
                message="Initial observation for voter",
            )

        # 4. Check for identical observation payload (different ID, same content)
        incoming_status_str = incoming.get("field_status")
        try:
            incoming_status = FieldStatusType(incoming_status_str)
        except ValueError:
            return ConflictAnalysisResult(
                conflict_type=ConflictType.INVALID_OBSERVATION,
                is_actionable=False,
                message=f"Invalid field status string: {incoming_status_str}",
            )

        if (
            latest_local_obs.field_status == incoming_status
            and (latest_local_obs.phone_number or "") == (incoming.get("phone_number") or "")
            and (latest_local_obs.notes or "") == (incoming.get("notes") or "")
        ):
            return ConflictAnalysisResult(
                conflict_type=ConflictType.IDENTICAL,
                is_actionable=False,
                message="Incoming observation matches latest local state exactly",
                existing_observation=latest_local_obs,
            )

        # 5. Parse timestamps for temporal comparison
        incoming_created_str = incoming.get("created_at")
        try:
            if isinstance(incoming_created_str, str):
                incoming_time = datetime.fromisoformat(incoming_created_str.replace("Z", "+00:00"))
            else:
                incoming_time = incoming_created_str
        except Exception:
            return ConflictAnalysisResult(
                conflict_type=ConflictType.INVALID_OBSERVATION,
                is_actionable=False,
                message="Invalid created_at timestamp format",
            )

        def _to_utc(dt: datetime) -> datetime:
            if dt.tzinfo is None:
                return dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)

        # 6. Check if incoming explicitly supersedes the local observation
        if incoming.get("supersedes_id") == latest_local_obs.observation_id:
            return ConflictAnalysisResult(
                conflict_type=None,
                is_actionable=True,
                message=f"Incoming explicitly supersedes observation {latest_local_obs.observation_id}",
                existing_observation=latest_local_obs,
            )

        # 7. Check for STALE observation (incoming is older than latest local state)
        if _to_utc(incoming_time) < _to_utc(latest_local_obs.created_at):
            return ConflictAnalysisResult(
                conflict_type=ConflictType.STALE,
                is_actionable=False,
                message=(
                    f"Incoming observation ({incoming_time.isoformat()}) is older than "
                    f"local observation ({latest_local_obs.created_at.isoformat()})"
                ),
                existing_observation=latest_local_obs,
            )

        # 8. CONCURRENT observation: different status, different origin, without explicit superseding
        return ConflictAnalysisResult(
            conflict_type=ConflictType.CONCURRENT,
            is_actionable=False,  # Divergent observations require human review
            message=(
                f"Concurrent divergent observations: local ({latest_local_obs.field_status.value}) vs "
                f"incoming ({incoming_status.value}) from device {incoming.get('origin_device_id')}"
            ),
            existing_observation=latest_local_obs,
        )

    @staticmethod
    def record_conflict(
        session: Session,
        voter: Voter,
        incoming: Dict[str, any],
        conflict_result: ConflictAnalysisResult,
    ) -> SyncConflict:
        """Record conflict entry in sync_conflicts and flag voter for review."""
        conflict = SyncConflict(
            voter_id=voter.id,
            voter_epic=voter.epic_number,
            conflict_type=conflict_result.conflict_type,
            local_observation_id=(
                conflict_result.existing_observation.observation_id
                if conflict_result.existing_observation
                else None
            ),
            incoming_observation_id=incoming.get("observation_id", ""),
            resolution_status=ConflictResolutionStatus.PENDING_REVIEW,
        )
        session.add(conflict)

        # Flag the voter in field_status as NEEDS_REVIEW
        if voter.field_status:
            voter.field_status.review_status = ReviewStatusType.NEEDS_REVIEW
            existing_reasons = voter.field_status.review_reasons or ""
            reason_text = f"Sync Conflict: {conflict_result.message}"
            if reason_text not in existing_reasons:
                voter.field_status.review_reasons = (
                    f"{existing_reasons}; {reason_text}".strip("; ")
                )

        return conflict

    @staticmethod
    def can_merge(
        local_status: FieldStatusType,
        incoming_status: FieldStatusType,
        local_phone: Optional[str] = None,
        incoming_phone: Optional[str] = None,
    ) -> Tuple[bool, Optional[str]]:
        """Determine whether observations can be safely and unambiguously merged."""
        if local_status != incoming_status:
            return False, f"Conflicting statuses ('{local_status.value}' vs '{incoming_status.value}') cannot be merged automatically"
        if local_phone and incoming_phone and local_phone != incoming_phone:
            return False, f"Conflicting phone numbers ('{local_phone}' vs '{incoming_phone}') require supervisor decision"
        return True, None

    @staticmethod
    def resolve_conflict(
        session: Session,
        conflict_id: str,
        choice: str,  # 'ACCEPT_A', 'ACCEPT_B', 'MERGE'
        resolver_user: str,
        notes: Optional[str] = None,
        merged_fields: Optional[Dict[str, Any]] = None,
        security_context: Optional[SecurityContext] = None,
    ) -> SyncConflict:
        """Resolve a sync conflict with an explicit supervisor decision."""
        if security_context:
            security_context.require_permission(Permission.RESOLVE_SYNC_CONFLICT)

        stmt = select(SyncConflict).where(SyncConflict.id == conflict_id)
        conflict = session.execute(stmt).scalars().first()
        if not conflict:
            raise ValueError(f"SyncConflict {conflict_id} not found")

        voter_stmt = select(Voter).where(Voter.epic_number == conflict.voter_epic)
        voter = session.execute(voter_stmt).scalars().first()
        if not voter:
            raise ValueError(f"Voter {conflict.voter_epic} not found")

        if choice == "ACCEPT_A":
            conflict.resolution_status = ConflictResolutionStatus.RESOLVED_ACCEPTED_A
        elif choice == "ACCEPT_B":
            conflict.resolution_status = ConflictResolutionStatus.RESOLVED_ACCEPTED_B
            # Materialize observation B into field_status
            stmt_b = select(FieldObservation).where(
                FieldObservation.observation_id == conflict.incoming_observation_id
            )
            obs_b = session.execute(stmt_b).scalars().first()
            if obs_b and voter.field_status:
                old_status = voter.field_status.status.value
                voter.field_status.status = obs_b.field_status
                voter.field_status.phone_number = obs_b.phone_number
                voter.field_status.notes = obs_b.notes
                voter.field_status.reported_by = obs_b.created_by
                voter.field_status.reported_at = obs_b.created_at

                # Append to audit history
                history = FieldStatusHistory(
                    voter_id=voter.id,
                    old_status=old_status,
                    new_status=obs_b.field_status.value,
                    notes=f"Resolved sync conflict by accepting incoming observation: {notes or ''}".strip(),
                    changed_by=resolver_user,
                    changed_at=datetime.now(timezone.utc),
                )
                session.add(history)
        elif choice == "MERGE":
            conflict.resolution_status = ConflictResolutionStatus.RESOLVED_MERGED
            # Handle merge logic
            stmt_b = select(FieldObservation).where(
                FieldObservation.observation_id == conflict.incoming_observation_id
            )
            obs_b = session.execute(stmt_b).scalars().first()

            if merged_fields:
                if voter.field_status:
                    old_status = voter.field_status.status.value
                    if "status" in merged_fields:
                        voter.field_status.status = FieldStatusType(merged_fields["status"])
                    if "phone_number" in merged_fields:
                        voter.field_status.phone_number = merged_fields["phone_number"]
                    if "notes" in merged_fields:
                        voter.field_status.notes = merged_fields["notes"]
                    voter.field_status.updated_at = utc_now()
                    history = FieldStatusHistory(
                        voter_id=voter.id,
                        old_status=old_status,
                        new_status=voter.field_status.status.value,
                        notes=f"Resolved sync conflict via explicit field merge: {notes or ''}".strip(),
                        changed_by=resolver_user,
                        changed_at=utc_now(),
                    )
                    session.add(history)
            else:
                # Automatic field merge validation
                if obs_b and voter.field_status:
                    can_do_merge, reason = ConflictEngine.can_merge(
                        voter.field_status.status,
                        obs_b.field_status,
                        voter.field_status.phone_number,
                        obs_b.phone_number,
                    )
                    if not can_do_merge:
                        raise ValueError(f"Ambiguous merge requires user decision: {reason}")
                    
                    old_status = voter.field_status.status.value
                    combined_notes = "; ".join(
                        filter(None, [voter.field_status.notes, obs_b.notes, notes])
                    )
                    voter.field_status.notes = combined_notes or None
                    if not voter.field_status.phone_number and obs_b.phone_number:
                        voter.field_status.phone_number = obs_b.phone_number

                    history = FieldStatusHistory(
                        voter_id=voter.id,
                        old_status=old_status,
                        new_status=voter.field_status.status.value,
                        notes=f"Resolved sync conflict by merging non-conflicting fields: {notes or ''}".strip(),
                        changed_by=resolver_user,
                        changed_at=utc_now(),
                    )
                    session.add(history)
        else:
            raise ValueError(f"Invalid conflict resolution choice: '{choice}'")

        conflict.resolved_by = resolver_user
        conflict.resolved_at = datetime.now(timezone.utc)
        conflict.resolution_choice = choice
        conflict.resolution_notes = notes

        # If no other pending conflicts exist for this voter, unflag review
        stmt_remaining = select(SyncConflict).where(
            SyncConflict.voter_epic == conflict.voter_epic,
            SyncConflict.resolution_status == ConflictResolutionStatus.PENDING_REVIEW,
            SyncConflict.id != conflict.id,
        )
        remaining = session.execute(stmt_remaining).scalars().all()
        if not remaining and voter.field_status:
            voter.field_status.review_status = ReviewStatusType.REVIEWED
            voter.field_status.reviewed_by = resolver_user
            voter.field_status.reviewed_at = datetime.now(timezone.utc)

        # Audit log conflict resolution
        AuditService(session).log(
            action="SYNC_CONFLICT_RESOLVED",
            entity_type="SyncConflict",
            entity_id=conflict.id,
            performed_by=resolver_user,
            details={
                "conflict_id": conflict.id,
                "voter_epic": conflict.voter_epic,
                "choice": choice,
                "notes": notes,
            },
        )

        return conflict
