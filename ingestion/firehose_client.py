from __future__ import annotations
import json
from typing import List, Dict, Any
import boto3
from botocore.config import Config


class FirehoseSink:
    def __init__(self, stream_name: str, region: str):
        self.stream_name = stream_name
        self.client = boto3.client(
            "firehose",
            region_name=region,
            config=Config(retries={"max_attempts": 5, "mode": "standard"}),
        )

    def put_records(self, records_json: List[Dict[str, Any]]) -> Dict[str, Any]:
        """
        Sends a batch to Firehose using PutRecordBatch. Each record is one NDJSON line.
        Max 500 records per request.
        """
        entries = [
            {"Data": (json.dumps(r, separators=(",", ":")) + "\n").encode("utf-8")}
            for r in records_json
        ]
        resp = self.client.put_record_batch(
            DeliveryStreamName=self.stream_name, Records=entries
        )
        return resp
