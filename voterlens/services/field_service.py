"""Field observation and local verification management service."""

from typing import Optional
from sqlalchemy.orm import Session

from voterlens.database.models import FieldStatusType
from voterlens.database.repository import FieldStatusRepository, VoterRepository
from voterlens.dto.voter_dto import FIELD_STATUS_LABELS, FieldStatusHistoryDTO, VoterFieldDTO
from voterlens.services.audit_service import AuditService
from voterlens.services.security import Permission, SecurityContext


class FieldStatusService:
    """Manages local field-worker observations, phone numbers, and verification audit trail.
    
    CRITICAL INVARIANT:
    Field actions NEVER modify official electoral roll voter records.
    """

    def __init__(self, session: Session):
        self.session = session
        self.field_repo = FieldStatusRepository(session)
        self.voter_repo = VoterRepository(session)
        self.audit = AuditService(session)

    def get_field_info(self, voter_id: str) -> VoterFieldDTO:
        """Fetch editable field record and complete transition history."""
        rec = self.field_repo.get_field_status_record(voter_id)
        history_records = self.field_repo.get_history(voter_id)
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
            for h in history_records
        ]

        if not rec:
            return VoterFieldDTO(
                status="NO_ISSUE",
                status_label=FIELD_STATUS_LABELS["NO_ISSUE"],
                history=history_dtos,
            )

        status_str = rec.status.value
        reasons = [r.strip() for r in (rec.review_reasons or "").split(",") if r.strip()]
        return VoterFieldDTO(
            status=status_str,
            status_label=FIELD_STATUS_LABELS.get(status_str, status_str),
            phone_number=rec.phone_number,
            notes=rec.notes,
            review_status=rec.review_status.value,
            review_reasons=reasons,
            reviewed_by=rec.reviewed_by,
            reviewed_at=rec.reviewed_at,
            reported_by=rec.reported_by,
            reported_at=rec.reported_at,
            history=history_dtos,
        )

    def set_status(
        self,
        voter_id: str,
        new_status: FieldStatusType,
        notes: Optional[str] = None,
        context: Optional[SecurityContext] = None,
    ) -> VoterFieldDTO:
        """Record a verified field observation (e.g. AWAY, ABROAD, DECEASED).
        
        Requires UPDATE_FIELD_STATUS permission.
        Guarantees that official Voter record remains 100% immutable.
        """
        if context:
            context.require_permission(Permission.UPDATE_FIELD_STATUS)

        reporter = context.username if context else "field_worker"
        old_status = self.field_repo.get_status(voter_id)
        
        self.field_repo.set_status(
            voter_id=voter_id,
            new_status=new_status,
            notes=notes,
            reported_by=reporter,
        )

        self.audit.log(
            action="FIELD_STATUS_CHANGED",
            entity_type="VOTER_FIELD",
            entity_id=voter_id,
            performed_by=reporter,
            details={
                "voter_id": voter_id,
                "old_status": old_status.value,
                "new_status": new_status.value,
                "notes": notes,
            },
        )
        return self.get_field_info(voter_id)

    def update_field_info(
        self,
        voter_id: str,
        phone_number: Optional[str] = None,
        notes: Optional[str] = None,
        status: Optional[FieldStatusType] = None,
        context: Optional[SecurityContext] = None,
    ) -> VoterFieldDTO:
        """Update permitted editable local fields (phone, notes, status)."""
        if context:
            context.require_permission(Permission.UPDATE_FIELD_STATUS)

        reporter = context.username if context else "field_worker"
        self.field_repo.update_field_information(
            voter_id=voter_id,
            phone_number=phone_number,
            notes=notes,
            status=status,
            reported_by=reporter,
        )

        if notes is not None:
            self.audit.log(
                action="FIELD_NOTE_UPDATED",
                entity_type="VOTER_FIELD",
                entity_id=voter_id,
                performed_by=reporter,
                details={"voter_id": voter_id},
            )

        return self.get_field_info(voter_id)

    def get_history(self, voter_id: str) -> list[FieldStatusHistoryDTO]:
        """Fetch complete chronological audit history for a voter."""
        records = self.field_repo.get_history(voter_id)
        return [
            FieldStatusHistoryDTO(
                id=h.id,
                voter_id=h.voter_id,
                old_status=h.old_status,
                new_status=h.new_status,
                notes=h.notes,
                changed_by=h.changed_by,
                changed_at=h.changed_at,
            )
            for h in records
        ]
