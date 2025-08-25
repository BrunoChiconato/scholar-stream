from __future__ import annotations

import os
import streamlit as st
from typing import Any, Dict, List, Tuple


try:
    from dotenv import load_dotenv
except Exception:  # noqa: BLE001
    load_dotenv = None

try:
    import pandas as pd
except Exception:  # noqa: BLE001
    pd = None  # type: ignore

try:
    import snowflake.connector as sf
except ImportError:  # pragma: no cover
    st.error(
        "Missing dependency: snowflake-connector-python."
        "Install it in your environment (requirements.txt) and rerun the app."
    )
    raise

if load_dotenv:
    load_dotenv(override=True)

APP_TITLE = "ScholarStream — Live Metrics"
DEFAULT_LIMIT = 50

ALLOWED_ROLES = [
    "ACCOUNTADMIN",
    "SYSADMIN",
    "R_INGEST",
    "R_TRANSFORM",
    "R_ANALYST",
]
ALLOWED_WAREHOUSES = ["WH_INGESTION", "WH_TRANSFORM", "WH_ANALYST"]
ALLOWED_DATABASES = ["SCHOLARSTREAM"]
ALLOWED_SCHEMAS = ["CURATED"]


def env(key: str, default: str | None = None) -> str | None:
    return os.getenv(key, default)


@st.cache_resource(show_spinner=False)
def get_connection(
    account: str,
    user: str,
    password: str,
    role: str | None = None,
    warehouse: str | None = None,
    database: str | None = None,
    schema: str | None = None,
):
    """Create a cached Snowflake connection (UTC session)."""
    params: Dict[str, Any] = {
        "account": account,
        "user": user,
        "password": password,
        "autocommit": True,
        "session_parameters": {"TIMEZONE": "UTC"},
    }
    if role:
        params["role"] = role
    if warehouse:
        params["warehouse"] = warehouse
    if database:
        params["database"] = database
    if schema:
        params["schema"] = schema
    conn = sf.connect(**params)  # type: ignore[arg-type]
    return conn


def _rows_to_df(cols: List[str], rows: List[Tuple[Any, ...]]):
    if pd is None:
        return [dict(zip(cols, r)) for r in rows]
    return pd.DataFrame(rows, columns=cols)


def run_query(conn, sql: str, params: Dict[str, Any] | None = None):
    cur = conn.cursor()
    try:
        cur.execute(sql, params or {})
        cols = [c[0] for c in cur.description] if cur.description else []
        rows = cur.fetchall() if cur.description else []
        return _rows_to_df(cols, rows)
    finally:
        cur.close()


def pick(options: List[str], default: str | None) -> str | None:
    if not options:
        return default
    if default and default in options:
        return default
    return options[0] if options else None


def selectbox_with_default(label: str, options: List[str], default: str | None) -> str:
    if not options:
        options = [""]

    idx = options.index(default) if default in options else 0
    return st.sidebar.selectbox(label, options=options, index=idx)


st.set_page_config(page_title=APP_TITLE, page_icon="📈", layout="wide")

st.sidebar.header("Context")
acc = env("SNOWFLAKE_ACCOUNT", "")
usr = env("SNOWFLAKE_USER", "")
pwd = env("SNOWFLAKE_PASSWORD", "")

if not acc or not usr or not pwd:
    st.warning("Configure Snowflake credentials in the sidebar (or .env) to connect.")
    st.stop()

role = selectbox_with_default("Role", ALLOWED_ROLES, env("SNOWFLAKE_ROLE", "R_ANALYST"))
wh = selectbox_with_default(
    "Warehouse", ALLOWED_WAREHOUSES, env("SNOWFLAKE_WAREHOUSE", "WH_ANALYST")
)
db = selectbox_with_default(
    "Database", ALLOWED_DATABASES, env("SNOWFLAKE_DATABASE", "SCHOLARSTREAM")
)
sch = selectbox_with_default(
    "Schema", ALLOWED_SCHEMAS, env("SNOWFLAKE_SCHEMA", "CURATED")
)

limit = st.sidebar.slider(
    "Rows (recent)", min_value=10, max_value=500, value=DEFAULT_LIMIT, step=10
)
refresh = st.sidebar.button("Refresh now")

conn = get_connection(acc, usr, pwd, role=role, warehouse=wh, database=db, schema=sch)

st.title(APP_TITLE)

lat_sql = (
    "SELECT AVG_SEC_5M, MIN_SEC_5M, MAX_SEC_5M, SAMPLES_5M, WINDOW_START, WINDOW_END "
    f"FROM {db}.{sch}.VW_LATENCY"
)

try:
    df_lat = run_query(conn, lat_sql)

    def _get_val(name: str):
        if pd is not None and isinstance(df_lat, pd.DataFrame):
            if df_lat.empty:
                return None
            val = df_lat.at[0, name]
            return (
                None
                if (
                    val is None
                    or (
                        hasattr(val, "__float__") is False and str(val).lower() == "nan"
                    )
                )
                else val
            )
        else:
            if not df_lat:
                return None
            return df_lat[0].get(name)

    def _to_float(x):
        try:
            return None if x is None else float(x)
        except Exception:
            return None

    avg_sec = _to_float(_get_val("AVG_SEC_5M"))
    min_sec = _to_float(_get_val("MIN_SEC_5M"))
    max_sec = _to_float(_get_val("MAX_SEC_5M"))
    samples_raw = _get_val("SAMPLES_5M")

    try:
        samples = int(samples_raw) if samples_raw is not None else 0
    except Exception:
        samples = 0

    if all(v is None for v in (avg_sec, min_sec, max_sec)) or samples == 0:
        st.info(
            "No recent data in the last 5 minutes. Start the producer to see metrics."
        )
    else:
        m1, m2, m3, m4 = st.columns(4)
        m1.metric("Avg Latency (5m)", f"{avg_sec:.1f}s" if avg_sec is not None else "—")
        m2.metric("Min (5m)", f"{min_sec:.0f}s" if min_sec is not None else "—")
        m3.metric("Max (5m)", f"{max_sec:.0f}s" if max_sec is not None else "—")
        m4.metric("Samples (5m)", f"{samples}")
except Exception as e:  # noqa: BLE001
    st.error(f"Failed to read VW_LATENCY: {e}")

st.divider()

rows_sql = (
    "SELECT WORK_ID, TITLE, PRIMARY_AUTHOR, PUBLICATION_YEAR, EMAIL, "
    "EVENT_TS, LANDED_TS, LATENCY_SECONDS "
    f"FROM {db}.{sch}.VW_WORKS "
    "ORDER BY LANDED_TS DESC "
    f"LIMIT {int(limit)}"
)

try:
    df_rows = run_query(conn, rows_sql)
    st.subheader("Recent works")

    if pd is not None and isinstance(df_rows, pd.DataFrame):
        st.dataframe(df_rows, use_container_width=True)
    else:
        st.write(df_rows)
except Exception as e:  # noqa: BLE001
    st.error(f"Failed to read VW_WORKS: {e}")


if refresh:
    st.toast("Refreshing…", icon="🔄")
    try:
        st.rerun()
    except AttributeError:  # compat older streamlit
        st.experimental_rerun()  # type: ignore[attr-defined]
