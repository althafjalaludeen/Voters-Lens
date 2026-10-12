"""SQLite FTS5 virtual table management and full-text search indexing for VoterLens."""

import re
from typing import Optional, Sequence
from sqlalchemy import text
from sqlalchemy.orm import Session


FTS_TABLE_NAME = "voters_fts"

CREATE_FTS_SQL = f"""
CREATE VIRTUAL TABLE IF NOT EXISTS {FTS_TABLE_NAME} USING fts5(
    voter_id UNINDEXED,
    roll_version_id UNINDEXED,
    name,
    normalized_name,
    relative_name,
    normalized_relative_name,
    house_number,
    epic_number,
    tokenize='unicode61 remove_diacritics 0'
);
"""


def ensure_fts_table(session: Session) -> None:
    """Ensure that the SQLite FTS5 table is created."""
    session.execute(text(CREATE_FTS_SQL))
    session.flush()


def rebuild_fts_index(session: Session, roll_version_id: Optional[str] = None) -> int:
    """Populate or synchronize FTS5 index from the official voters table.
    
    Returns the number of indexed records.
    """
    ensure_fts_table(session)
    
    if roll_version_id:
        session.execute(
            text(f"DELETE FROM {FTS_TABLE_NAME} WHERE roll_version_id = :roll_id"),
            {"roll_id": roll_version_id},
        )
        insert_sql = f"""
        INSERT INTO {FTS_TABLE_NAME} (
            voter_id, roll_version_id, name, normalized_name,
            relative_name, normalized_relative_name, house_number, epic_number
        )
        SELECT 
            id, roll_version_id, name, normalized_name,
            relative_name, normalized_relative_name, house_number, epic_number
        FROM voters
        WHERE roll_version_id = :roll_id;
        """
        result = session.execute(text(insert_sql), {"roll_id": roll_version_id})
    else:
        session.execute(text(f"DELETE FROM {FTS_TABLE_NAME}"))
        insert_sql = f"""
        INSERT INTO {FTS_TABLE_NAME} (
            voter_id, roll_version_id, name, normalized_name,
            relative_name, normalized_relative_name, house_number, epic_number
        )
        SELECT 
            id, roll_version_id, name, normalized_name,
            relative_name, normalized_relative_name, house_number, epic_number
        FROM voters;
        """
        result = session.execute(text(insert_sql))
        
    session.flush()
    return result.rowcount if result.rowcount is not None else 0


def sanitize_fts_query(term: str) -> str:
    """Sanitize user query term for safe FTS5 MATCH execution without syntax errors."""
    clean = term.strip()
    # Strip FTS5 operators like AND, OR, NOT, NEAR or special chars if lone
    clean = re.sub(r'["*^:]', '', clean)
    tokens = clean.split()
    if not tokens:
        return ""
    # Use prefix matching for tokens: e.g. "സുരേഷ്*" or "suresh*"
    return " ".join(f'"{t}"*' for t in tokens)


def search_fts_voter_ids(
    session: Session,
    roll_version_id: str,
    query: str,
    limit: int = 50,
    offset: int = 0,
) -> Sequence[str]:
    """Execute FTS5 search query and return matching voter IDs ordered by BM25 rank."""
    ensure_fts_table(session)
    fts_expr = sanitize_fts_query(query)
    if not fts_expr:
        return []

    sql = f"""
    SELECT voter_id 
    FROM {FTS_TABLE_NAME}
    WHERE roll_version_id = :roll_id AND {FTS_TABLE_NAME} MATCH :query
    ORDER BY rank
    LIMIT :limit OFFSET :offset;
    """
    try:
        rows = session.execute(
            text(sql),
            {"roll_id": roll_version_id, "query": fts_expr, "limit": limit, "offset": offset},
        ).fetchall()
        return [row[0] for row in rows]
    except Exception:
        # Graceful fallback if FTS table is empty or query has issue
        return []
