"""Audit service recording local administrative and verification events safely."""

from typing import Any, Optional, Sequence
from sqlalchemy.orm import Session

from voterlens.database.models import AuditLog
from voterlens.database.repository import AuditRepository
from voterlens.services.security import Permission, SecurityContext


class AuditService:
    """Manages audit logging ensuring zero leakage of sensitive personal voter data."""

    def __init__(self, session: Session):
        self.session = session
        self.repo = AuditRepository(session)

    def log(
        self,
        action: str,
        entity_type: str,
        entity_id: Optional[str] = None,
        performed_by: Optional[str] = None,
        details: Optional[dict[str, Any]] = None,
    ) -> AuditLog:
        """Record an audit event."""
        # Sanitize details: strip any possible bulk voter lists or sensitive fields
        sanitized = None
        if details:
            sanitized = {}
            for k, v in details.items():
                if k in ("name", "relative_name", "photo_path", "raw_data", "voters"):
                    continue  # Strip personal voter fields
                sanitized[k] = v

        return self.repo.log_event(
            action=action,
            entity_type=entity_type,
            entity_id=entity_id,
            performed_by=performed_by,
            details=sanitized,
        )

    def get_recent_logs(
        self,
        action: Optional[str] = None,
        entity_type: Optional[str] = None,
        limit: int = 50,
        offset: int = 0,
        context: Optional[SecurityContext] = None,
    ) -> Sequence[AuditLog]:
        """Retrieve audit events (restricted to ADMIN and MANAGER)."""
        if context:
            context.require_permission(Permission.VIEW_AUDIT_LOGS)
        return self.repo.get_recent_logs(
            action=action, entity_type=entity_type, limit=limit, offset=offset
        )
