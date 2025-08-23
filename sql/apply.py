"""
Snowflake SQL script executor for the ScholarStream project.

• Reads .sql files in the directory (by default, this apply.py's directory),
  in numerical prefix order (e.g., 01_, 02_, 03_ ...).
• Connects to Snowflake using environment variables (.env) and executes each script
  with support for multiple statements via execute_stream.
• Useful flags:
    --files                 List of specific files to execute (order preserved)
    --dir                   Base directory for the .sql files (default: this apply.py's folder)
    --dry-run               Only lists the execution order, does not execute
    --continue-on-error     Continues to the next file if an error occurs (default: stops)
    --verbose               Detailed logs (DEBUG)

Expected environment variables (loaded via python-dotenv, if .env is present):
  SNOWFLAKE_ACCOUNT   (e.g., abcd-xy12345)
  SNOWFLAKE_USER
  SNOWFLAKE_PASSWORD  (or using connections via connections.toml; see docstring below)
  SNOWFLAKE_ROLE      (optional; the .sql files already use USE ROLE when necessary)
  SNOWFLAKE_WAREHOUSE (optional)
  SNOWFLAKE_DATABASE  (optional)

Requirements: snowflake-connector-python, python-dotenv
"""

from __future__ import annotations

import argparse
import logging
import os
import re
from pathlib import Path
from typing import Iterable, List
from io import StringIO

from dotenv import load_dotenv
import snowflake.connector as sf

load_dotenv(override=False)


def _natural_sql_order(files: Iterable[Path]) -> List[Path]:
    def key(p: Path):
        m = re.match(r"^(\d+)", p.name)
        return (int(m.group(1)) if m else 1_000_000, p.name)

    return sorted([f for f in files if f.suffix.lower() == ".sql"], key=key)


def _resolve_files(base_dir: Path, selected: List[str] | None) -> List[Path]:
    if selected:
        paths = [Path(s) if s.endswith(".sql") else base_dir / s for s in selected]
        return [
            p if p.is_absolute() else (p if p.exists() else base_dir / p) for p in paths
        ]

    return _natural_sql_order(base_dir.glob("*.sql"))


def connect_from_env() -> sf.SnowflakeConnection:
    params = {
        "account": os.getenv("SNOWFLAKE_ACCOUNT"),
        "user": os.getenv("SNOWFLAKE_USER"),
        "password": os.getenv("SNOWFLAKE_PASSWORD"),
        "role": os.getenv("SNOWFLAKE_ROLE"),
        "warehouse": os.getenv("SNOWFLAKE_WAREHOUSE"),
        "database": os.getenv("SNOWFLAKE_DATABASE"),
        "autocommit": True,
    }

    clean = {k: v for k, v in params.items() if v}

    conn = sf.connect(**clean)  # type: ignore[arg-type]
    return conn


def execute_sql_file(
    conn: sf.SnowflakeConnection, path: Path, remove_comments: bool = True
) -> None:
    logging.info("▶ Executing: %s", path)
    sql_text = path.read_text(encoding="utf-8")

    for cur in conn.execute_stream(StringIO(sql_text), remove_comments=remove_comments):  # type: ignore[attr-defined]
        try:
            _ = cur.fetchall() if cur.description else None
            qid = getattr(cur, "sfqid", None)
            if qid:
                logging.debug("  • OK (query_id=%s, rowcount=%s)", qid, cur.rowcount)
        finally:
            cur.close()

    logging.info("✔ Complete: %s", path.name)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Applies SQL scripts to Snowflake in order."
    )
    parser.add_argument(
        "--dir",
        dest="dir",
        default=str(Path(__file__).resolve().parent),
        help="Directory containing the .sql files (default: this apply.py's folder)",
    )
    parser.add_argument(
        "--files",
        nargs="*",
        help="Specific files to execute (e.g., 01_init_snowflake.sql 02_rbac_policies.sql)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Only lists the execution order without executing",
    )
    parser.add_argument(
        "--continue-on-error",
        action="store_true",
        help="Continues to the next file if an error occurs (default: stops)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Activates DEBUG logs",
    )

    args = parser.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s | %(levelname)s | %(message)s",
    )

    base_dir = Path(args.dir).resolve()
    if not base_dir.exists() or not base_dir.is_dir():
        logging.error("Invalid directory: %s", base_dir)
        return 2

    files = _resolve_files(base_dir, args.files)
    files = [f.resolve() for f in files if f.exists()]

    if not files:
        logging.error("No .sql files found in %s", base_dir)
        return 3

    logging.info("Execution order (%d files):", len(files))
    for f in files:
        logging.info("  - %s", f.name)

    if args.dry_run:
        return 0

    try:
        conn = connect_from_env()
    except Exception as e:  # noqa: BLE001
        logging.exception("Failed to connect to Snowflake: %s", e)
        return 4

    try:
        for path in files:
            try:
                execute_sql_file(conn, path)
            except Exception as e:  # noqa: BLE001
                logging.exception("Error executing %s: %s", path.name, e)
                if not args.continue_on_error:
                    return 5
    finally:
        try:
            conn.close()
        except Exception:  # pragma: no cover
            pass

    logging.info("All scripts executed successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
