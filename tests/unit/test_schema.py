from ingestion.schema import OpenAlexWork, Envelope


def test_openalexwork_ignores_extras(sample_openalex_item):
    w = OpenAlexWork.model_validate(sample_openalex_item)
    assert w.id == "W123"
    assert not hasattr(w, "extra_field")


def test_envelope_from_openalex_maps_fields_and_alias(sample_openalex_item, fixed_now):
    w = OpenAlexWork.model_validate(sample_openalex_item)
    env = Envelope.from_openalex(
        w, event_ts=fixed_now, ingest_ts=fixed_now, email="x@ex.com", source="openalex"
    )
    d = env.model_dump(by_alias=True, mode="json")
    assert d["id"] == "W123"
    assert d["primary_author"] == "Alice Smith"
    assert d["host_venue"] == "VenueX"
    assert "_LOAD_ID" in d and isinstance(d["_LOAD_ID"], str) and d["_LOAD_ID"]
