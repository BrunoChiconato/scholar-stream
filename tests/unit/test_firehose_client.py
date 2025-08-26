import json
import types
from ingestion.firehose_client import FirehoseSink


class FakeBotoClient:
    def __init__(self):
        self.calls = []

    def put_record_batch(self, DeliveryStreamName, Records):
        self.calls.append((DeliveryStreamName, Records))
        return {
            "FailedPutCount": 0,
            "RequestResponses": [{"RecordId": "ok"} for _ in Records],
        }


def test_firehose_sink_put_records_encodes_ndjson(monkeypatch):
    fake = FakeBotoClient()

    def fake_boto3_client(name, region_name=None, config=None):
        assert name == "firehose"
        return fake

    import ingestion.firehose_client as fhm

    monkeypatch.setattr(fhm, "boto3", types.SimpleNamespace(client=fake_boto3_client))

    sink = FirehoseSink(stream_name="s", region="us-east-1")
    resp = sink.put_records([{"a": 1}, {"b": 2}])

    assert resp["FailedPutCount"] == 0
    assert fake.calls, "put_record_batch should be called"
    stream, records = fake.calls[-1]
    assert stream == "s"
    payloads = [r["Data"] for r in records]
    assert all(isinstance(p, (bytes, bytearray)) for p in payloads)
    assert all(p.endswith(b"\n") for p in payloads)
    assert payloads[0].strip() == json.dumps({"a": 1}, separators=(",", ":")).encode()
