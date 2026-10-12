"""Security and Role-Based Access Control (RBAC) layer for VoterLens."""

from enum import Enum
from typing import Optional

from voterlens.database.models import User, UserRole


class Permission(str, Enum):
    """Granular permissions enforced across the service and data layer."""
    MANAGE_ROLLS = "MANAGE_ROLLS"
    ACTIVATE_ROLL = "ACTIVATE_ROLL"
    MANAGE_USERS = "MANAGE_USERS"
    VIEW_AUDIT_LOGS = "VIEW_AUDIT_LOGS"
    VIEW_VOTERS = "VIEW_VOTERS"
    SEARCH_VOTERS = "SEARCH_VOTERS"
    UPDATE_FIELD_STATUS = "UPDATE_FIELD_STATUS"
    REVIEW_RECORDS = "REVIEW_RECORDS"
    EXPORT_SYNC = "EXPORT_SYNC"
    IMPORT_SYNC = "IMPORT_SYNC"
    RESOLVE_SYNC_CONFLICT = "RESOLVE_SYNC_CONFLICT"
    BACKUP_RESTORE = "BACKUP_RESTORE"


ROLE_PERMISSIONS: dict[UserRole, set[Permission]] = {
    UserRole.ADMIN: {
        Permission.MANAGE_ROLLS,
        Permission.ACTIVATE_ROLL,
        Permission.MANAGE_USERS,
        Permission.VIEW_AUDIT_LOGS,
        Permission.VIEW_VOTERS,
        Permission.SEARCH_VOTERS,
        Permission.UPDATE_FIELD_STATUS,
        Permission.REVIEW_RECORDS,
        Permission.EXPORT_SYNC,
        Permission.IMPORT_SYNC,
        Permission.RESOLVE_SYNC_CONFLICT,
        Permission.BACKUP_RESTORE,
    },
    UserRole.MANAGER: {
        Permission.VIEW_VOTERS,
        Permission.SEARCH_VOTERS,
        Permission.UPDATE_FIELD_STATUS,
        Permission.REVIEW_RECORDS,
        Permission.VIEW_AUDIT_LOGS,
        Permission.EXPORT_SYNC,
        Permission.IMPORT_SYNC,
        Permission.RESOLVE_SYNC_CONFLICT,
    },
    UserRole.FIELD_USER: {
        Permission.VIEW_VOTERS,
        Permission.SEARCH_VOTERS,
        Permission.UPDATE_FIELD_STATUS,
        Permission.EXPORT_SYNC,
    },
    UserRole.VIEWER: {
        Permission.VIEW_VOTERS,
        Permission.SEARCH_VOTERS,
    },
}


class PermissionDeniedError(Exception):
    """Raised when an operation violates Role-Based Access Control rules."""
    pass


class SecurityContext:
    """Security context holding caller identity and enforcing permissions."""

    def __init__(
        self,
        user: Optional[User] = None,
        username: str = "system",
        role: UserRole = UserRole.ADMIN,
    ):
        if user:
            self.user = user
            self.username = user.username
            self.role = user.role
        else:
            self.user = None
            self.username = username
            self.role = role

    def has_permission(self, permission: Permission) -> bool:
        """Check if current context holds the given permission."""
        allowed = ROLE_PERMISSIONS.get(self.role, set())
        return permission in allowed

    def require_permission(self, permission: Permission) -> None:
        """Enforce permission check, raising PermissionDeniedError if unauthorized."""
        if not self.has_permission(permission):
            raise PermissionDeniedError(
                f"User '{self.username}' with role '{self.role.value}' is not authorized "
                f"for permission '{permission.value}'."
            )

    @classmethod
    def system(cls) -> "SecurityContext":
        """Pre-authorized system context for offline batch operations and tests."""
        return cls(username="system", role=UserRole.ADMIN)

    @classmethod
    def viewer(cls, username: str = "guest_viewer") -> "SecurityContext":
        """Read-only viewer context."""
        return cls(username=username, role=UserRole.VIEWER)

    @classmethod
    def field_user(cls, username: str = "field_worker") -> "SecurityContext":
        """Field user context permitted to submit observations."""
        return cls(username=username, role=UserRole.FIELD_USER)

    @classmethod
    def manager(cls, username: str = "local_manager") -> "SecurityContext":
        """Local manager context."""
        return cls(username=username, role=UserRole.MANAGER)

    @classmethod
    def admin(cls, username: str = "local_admin") -> "SecurityContext":
        """Local administrator context."""
        return cls(username=username, role=UserRole.ADMIN)
