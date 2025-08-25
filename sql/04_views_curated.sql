USE ROLE R_TRANSFORM;
USE WAREHOUSE WH_TRANSFORM;
USE DATABASE SCHOLARSTREAM;
USE SCHEMA CURATED;

CREATE OR REPLACE VIEW VW_WORKS AS
WITH base AS (
    SELECT
        r.RECORD AS rec,
        r.RECORD_METADATA AS meta
    FROM
        SCHOLARSTREAM.RAW.OPENALEX_EVENTS AS r
),
timed AS (
    SELECT
        rec,
        meta,
        TRY_TO_TIMESTAMP_TZ(rec:"event_ts"::string) AS event_ts,
        TRY_TO_TIMESTAMP_TZ(rec:"ingest_ts"::string) AS ingest_ts,
        COALESCE(
            TRY_TO_TIMESTAMP_TZ(meta:"IngestionTime"::string),
            TRY_TO_TIMESTAMP_TZ(rec:"ingest_ts"::string),
            CURRENT_TIMESTAMP()
        ) AS landed_ts
    FROM
        base
)
SELECT
    rec:"id"::string AS work_id,
    rec:"doi"::string AS doi,
    rec:"title"::string AS title,
    TRY_TO_NUMBER(TO_VARCHAR(rec:"publication_year"))AS publication_year,
    rec:"host_venue":"display_name"::string AS venue,
    rec:"authorships"[0]:"author":"display_name"::string AS primary_author,
    rec:"email"::string AS email,
    event_ts,
    ingest_ts,
    landed_ts,
    CASE
        WHEN event_ts IS NOT NULL THEN DATEDIFF('second', event_ts, landed_ts)
        ELSE NULL
    END AS latency_seconds
FROM
    timed;

COMMENT ON VIEW VW_WORKS IS 'Curated projection of OpenAlex works from VARIANT (safe casts + latency).';

CREATE OR REPLACE VIEW VW_LATENCY AS
    SELECT
        AVG(latency_seconds) AS avg_sec_5m,
        MIN(latency_seconds) AS min_sec_5m,
        MAX(latency_seconds) AS max_sec_5m,
        COUNT(*) AS samples_5m,
        DATEADD(minute, -5, CURRENT_TIMESTAMP()) AS window_start,
        CURRENT_TIMESTAMP() AS window_end
    FROM
        CURATED.VW_WORKS
    WHERE
        event_ts IS NOT NULL
        AND landed_ts >= DATEADD(minute, -5, CURRENT_TIMESTAMP());

COMMENT ON VIEW VW_LATENCY IS 'Latency metrics (avg/min/max) over last 5 minutes using Firehose metadata.';
