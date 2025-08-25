"""OpenAlex → Firehose producer.

Fetches OpenAlex works with cursor pagination, validates/normalizes them
into a canonical envelope, and sends NDJSON batches to an Amazon
Kinesis Data Firehose delivery stream (destination: Snowflake).

CLI examples:
  python -m ingestion.producer --dry-run --batch-size 3 --max-pages 1
  python -m ingestion.producer --batch-size 50 --batch-sleep 1

This module supports the historical form used in your Makefile:
  python -m ingestion.producer run --batch-size 50 --batch-sleep 1
by stripping the literal "run" from argv (see _strip_run_alias).
"""

from __future__ import annotations
import sys
from datetime import datetime, timezone
from typing import Optional, List

import typer
from rich import print, box
from rich.table import Table

from ingestion.config import Settings
from ingestion.openalex_client import OpenAlexClient
from ingestion.firehose_client import FirehoseSink
from ingestion.schema import OpenAlexWork, Envelope
from ingestion.utils import synthetic_email


def main(
    per_page: int = typer.Option(50, help="OpenAlex page size"),
    updated_since: Optional[str] = typer.Option(
        None, help="Filter works updated since (YYYY-MM-DD)"
    ),
    max_pages: Optional[int] = typer.Option(None, help="Stop after N pages"),
    batch_size: Optional[int] = typer.Option(
        None,
        help="Firehose batch size (<=500). Default from env PRODUCER_BATCH_SIZE or 50",
    ),
    batch_sleep: Optional[float] = typer.Option(
        None,
        help="Sleep between OpenAlex pages (seconds). Default from env PRODUCER_SLEEP_SECONDS or 2",
    ),
    dry_run: bool = typer.Option(
        False, help="Do not send to Firehose, just print counts"
    ),
) -> None:
    """Run the producer.

    Notes
    -----
    * Firehose PutRecordBatch supports up to 500 records per request.
    * Each record is written as a single NDJSON line (UTF-8 encoded).
    * The Snowflake target table should contain RECORD (VARIANT) and
      RECORD_METADATA (VARIANT/OBJECT) when using VARIANT_CONTENT_AND_METADATA_MAPPING.
    """
    cfg = Settings()
    cfg.validate()

    # Allow CLI to override .env defaults, but keep env as fallback
    eff_batch_size = batch_size or cfg.batch_size
    eff_batch_sleep = batch_sleep if batch_sleep is not None else cfg.sleep_seconds

    if eff_batch_size <= 0 or eff_batch_size > 500:
        raise typer.BadParameter(
            "batch_size must be between 1 and 500 for Firehose PutRecordBatch"
        )

    print(
        f"[bold]Producer starting[/bold] | stream=[cyan]{cfg.firehose_name}[/cyan] | region=[cyan]{cfg.aws_region}[/cyan] | per_page={per_page} | batch={eff_batch_size} | sleep={eff_batch_sleep}s | dry_run={dry_run}"
    )

    oa = OpenAlexClient(base_url=cfg.openalex_base_url, mailto=cfg.openalex_email)
    sink = FirehoseSink(stream_name=cfg.firehose_name, region=cfg.aws_region)

    total_sent, total_failed = 0, 0
    batch: List[Envelope] = []

    for raw in oa.works_stream(
        per_page=per_page,
        updated_since=updated_since,
        max_pages=max_pages,
        sleep_seconds=eff_batch_sleep,
    ):
        now = datetime.now(timezone.utc)
        w = OpenAlexWork.model_validate(raw)
        email = w.email or synthetic_email(
            (
                w.authorships[0].author.display_name
                if (w.authorships and w.authorships[0].author)
                else None
            )
        )
        env = Envelope.from_openalex(
            w, event_ts=now, ingest_ts=now, email=email, source=cfg.source
        )
        batch.append(env)

        if len(batch) >= eff_batch_size:
            total_sent, total_failed = flush(
                batch, sink, dry_run, total_sent, total_failed
            )
            batch = []

    # Flush remainder
    if batch:
        total_sent, total_failed = flush(batch, sink, dry_run, total_sent, total_failed)

    # Summary table
    table = Table(title="Producer summary", box=box.MINIMAL_DOUBLE_HEAD)
    table.add_column("Sent")
    table.add_column("Failed")
    table.add_row(str(total_sent), str(total_failed))
    print(table)

    if total_failed:
        print(
            "[yellow]Some records failed. Check Firehose CloudWatch Logs and the S3 error prefix for details.[/yellow]"
        )


def flush(
    batch: List[Envelope], sink: FirehoseSink, dry_run: bool, total: int, failed: int
):
    """Send a batch to Firehose and return updated counters.

    Serializes with Pydantic aliases (by_alias=True) so fields like
    `_LOAD_ID` are present in the JSON payload.
    """
    records = [
        b.model_dump(by_alias=True, mode="json", exclude_none=True) for b in batch
    ]

    if dry_run:
        print(f"[yellow]Dry-run:[/yellow] would send {len(records)} records")
        return total, failed

    resp = sink.put_records(records)
    total += len(records)

    failed_count = int(resp.get("FailedPutCount", 0) or 0)
    failed += failed_count

    # Optionally surface first few error reasons for quick diagnosis
    if failed_count:
        rr = resp.get("RequestResponses", [])
        examples = []
        for r in rr:
            if r.get("ErrorCode") or r.get("ErrorMessage"):
                examples.append((r.get("ErrorCode"), r.get("ErrorMessage")))
            if len(examples) >= 3:
                break
        if examples:
            print("[red]Firehose batch had failures:[/red]")
            for code, msg in examples:
                print(f"  • {code}: {msg}")

    return total, failed


def _strip_run_alias(argv: list[str]) -> None:
    """Support legacy invocation: `python -m ingestion.producer run ...`.
    If the second token is the literal 'run', drop it so Typer parses options.
    """
    if len(argv) > 1 and argv[1] == "run":
        del argv[1]


if __name__ == "__main__":
    _strip_run_alias(sys.argv)
    typer.run(main)
