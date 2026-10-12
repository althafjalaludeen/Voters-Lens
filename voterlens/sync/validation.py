"""Validation rules for field observations prior to synchronization packaging."""

from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple
import uuid

from voterlens.database.models import FieldStatusType


class ObservationValidationError(ValueError):
    """Raised when an individual field observation violates schema or consistency rules."""
    pass


def validate_observation_for_export(
    obs: Dict[str, Any],
    expected_roll_checksum: str,
) -> Tuple[bool, Optional[str]]:
    """Validate a single field observation dictionary against Phase 4A/4B constraints.
    
    Args:
        obs: Dictionary of observation attributes.
        expected_roll_checksum: Expected active roll SHA-256 checksum.
        
    Returns:
        Tuple of (is_valid: bool, error_reason: Optional[str]).
    """
    # 1. Observation ID UUIDv4 validation
    obs_id = obs.get("observation_id")
    if not obs_id or not isinstance(obs_id, str):
        return False, "Missing or non-string observation_id"
    try:
        uuid_obj = uuid.UUID(obs_id, version=4)
        if str(uuid_obj) != obs_id.lower():
            # Accept if standard UUID string representation
            pass
    except (ValueError, AttributeError):
        return False, f"Invalid UUIDv4 format for observation_id: '{obs_id}'"

    # 2. Voter identity validation
    voter_epic = obs.get("voter_epic")
    if not voter_epic or not isinstance(voter_epic, str) or not voter_epic.strip():
        return False, "Missing or empty voter_epic"

    # 3. Roll checksum validation
    roll_checksum = obs.get("roll_checksum")
    if not roll_checksum or roll_checksum != expected_roll_checksum:
        return False, (
            f"Roll checksum mismatch: observation has '{roll_checksum}', "
            f"expected '{expected_roll_checksum}'"
        )

    # 4. Field status validation
    status_str = obs.get("field_status")
    if not status_str or not isinstance(status_str, str):
        return False, "Missing or empty field_status"
    try:
        FieldStatusType(status_str)
    except ValueError:
        return False, f"Invalid FieldStatusType: '{status_str}'"

    # 5. Creator validation
    creator = obs.get("created_by")
    if not creator or not isinstance(creator, str) or not creator.strip():
        return False, "Missing or empty created_by"

    # 6. Timestamp validation (ISO8601 UTC)
    created_at_raw = obs.get("created_at")
    if not created_at_raw:
        return False, "Missing created_at timestamp"
    try:
        if isinstance(created_at_raw, str):
            dt = datetime.fromisoformat(created_at_raw.replace("Z", "+00:00"))
        elif isinstance(created_at_raw, datetime):
            dt = created_at_raw
        else:
            return False, f"Unsupported created_at type: {type(created_at_raw)}"
    except Exception as exc:
        return False, f"Malformed ISO8601 created_at timestamp: {exc}"

    # 7. Origin device ID validation
    origin_device = obs.get("origin_device_id")
    if not origin_device or not isinstance(origin_device, str):
        return False, "Missing or empty origin_device_id"
    try:
        uuid.UUID(origin_device)
    except ValueError:
        return False, f"Invalid UUID format for origin_device_id: '{origin_device}'"

    # 8. Supersedes relationship validation (if present, must be valid UUID)
    supersedes = obs.get("supersedes_id")
    if supersedes is not None:
        if not isinstance(supersedes, str) or not supersedes.strip():
            return False, "Malformed supersedes_id"
        try:
            uuid.UUID(supersedes)
        except ValueError:
            return False, f"Invalid UUID format for supersedes_id: '{supersedes}'"

    # 9. Revocation flag validation
    is_revoked = obs.get("is_revoked")
    if is_revoked is not None and not isinstance(is_revoked, bool):
        return False, "is_revoked must be a boolean"

    return True, None


def filter_valid_observations_for_export(
    raw_observations: List[Dict[str, Any]],
    expected_roll_checksum: str,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """Partition observation candidates into valid list and excluded list with diagnostics.
    
    Returns:
        Tuple of (valid_observations, excluded_records_with_reasons).
    """
    valid = []
    excluded = []
    for obs in raw_observations:
        is_ok, reason = validate_observation_for_export(obs, expected_roll_checksum)
        if is_ok:
            valid.append(obs)
        else:
            excluded.append({
                "observation": obs,
                "reason": reason,
                "observation_id": obs.get("observation_id", "UNKNOWN"),
                "voter_epic": obs.get("voter_epic", "UNKNOWN"),
            })
    return valid, excluded
