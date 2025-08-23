USE ROLE R_TRANSFORM;
USE WAREHOUSE WH_TRANSFORM;
USE DATABASE SCHOLARSTREAM;
USE SCHEMA CURATED;

CREATE OR REPLACE VIEW VW_WORKS AS
SELECT
    r.RECORD:id::string AS work_id,
    r.RECORD:doi::string AS doi,
    r.RECORD:title::string AS title,
    TRY_TO_NUMBER(r.RECORD:publication_year) AS publication_year,
    r.RECORD:host_venue:display_name::string AS venue, 
    r.RECORD:authorships[0]:author:display_name::string AS primary_author,  
    r.RECORD:email::string AS email, 
    r.EVENT_TS,
    r.INGEST_TS,
    r.LANDED_TS,
    DATEDIFF('second', r.EVENT_TS, r.LANDED_TS) AS latency_seconds
FROM
    SCHOLARSTREAM.RAW.OPENALEX_EVENTS AS r;

COMMENT ON VIEW VW_WORKS IS 'Curated projection of OpenAlex works (safe casts + latency).';

CREATE OR REPLACE VIEW VW_LATENCY AS
SELECT
    AVG(latency_seconds) AS avg_sec_5m,
    MIN(latency_seconds) AS min_sec_5m,
    MAX(latency_seconds) AS max_sec_5m,
    COUNT(*) AS samples_5m,
    DATEADD('minute', -5, CURRENT_TIMESTAMP()) AS window_start,
    CURRENT_TIMESTAMP() AS window_end
FROM
    VW_WORKS
WHERE
    LANDED_TS >= DATEADD('minute', -5, CURRENT_TIMESTAMP());

COMMENT ON VIEW VW_LATENCY IS 'Latency metrics (avg/min/max) over last 5 minutes.';
