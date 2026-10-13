from bookkeeping_agent.category_store import (
    apply_categories,
    load_category_map,
    lookup,
    save_category_map,
    store_path,
)


def test_load_missing_returns_empty_scaffold(tmp_path):
    store = load_category_map(tmp_path)
    assert store["merchants"] == {}
    assert store["house_chart"] == []
    assert not store_path(tmp_path).exists()  # load must not create the file


def test_save_then_load_roundtrip(tmp_path):
    summary = save_category_map(
        tmp_path,
        {"Netflix": "entertainment", "SQ *Blue Bottle #9": {"category": "coffee", "confidence": "high"}},
        house_chart=["entertainment", "coffee", "groceries"],
    )
    assert summary["merchant_count"] == 2
    assert set(summary["added"]) == {"netflix", "blue bottle"}
    assert store_path(tmp_path).is_file()

    store = load_category_map(tmp_path)
    assert store["merchants"]["netflix"]["category"] == "entertainment"
    assert store["merchants"]["blue bottle"]["confidence"] == "high"
    assert store["house_chart"] == ["entertainment", "coffee", "groceries"]


def test_merge_upserts_without_clobbering(tmp_path):
    save_category_map(tmp_path, {"Netflix": "entertainment"})
    summary = save_category_map(tmp_path, {"Netflix": "streaming", "Hulu": "entertainment"})
    assert summary["updated"] == ["netflix"]
    assert summary["added"] == ["hulu"]
    store = load_category_map(tmp_path)
    assert store["merchants"]["netflix"]["category"] == "streaming"
    assert store["merchants"]["hulu"]["category"] == "entertainment"


def test_merge_false_replaces(tmp_path):
    save_category_map(tmp_path, {"Netflix": "entertainment", "Hulu": "entertainment"})
    save_category_map(tmp_path, {"Spotify": "music"}, merge=False)
    store = load_category_map(tmp_path)
    assert set(store["merchants"]) == {"spotify"}


def test_skips_invalid_entries(tmp_path):
    summary = save_category_map(tmp_path, {"Netflix": "entertainment", "": "x", "Bad": {"note": "no category"}})
    assert "Bad" in summary["skipped"]
    assert summary["merchant_count"] == 1


def test_malformed_store_reports_error(tmp_path):
    path = store_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{not json", encoding="utf-8")
    store = load_category_map(tmp_path)
    assert "error" in store
    assert store["merchants"] == {}


def test_lookup_normalizes_key(tmp_path):
    save_category_map(tmp_path, {"Starbucks": "coffee"})
    store = load_category_map(tmp_path)
    assert lookup(store, "SQ *STARBUCKS #142")["category"] == "coffee"
    assert lookup(store, "Unknown Shop") is None


def test_apply_categories_tags_rows_and_lists_uncoded(tmp_path):
    save_category_map(tmp_path, {"Netflix": "entertainment"})
    store = load_category_map(tmp_path)
    rows = [
        {"merchant": "Netflix", "amount": 15.49},
        {"merchant": "SQ *STARBUCKS #142", "amount": 6.45},
        {"merchant": "Starbucks", "amount": 5.10},
    ]
    result = apply_categories(rows, store)
    assert result["coded"] == 1
    assert result["rows"][0]["house_category"] == "entertainment"
    assert result["rows"][0]["house_category_source"] == "memory"
    assert result["rows"][1]["house_category"] is None
    # Both Starbucks variants collapse to a single uncoded merchant (normalized).
    assert result["uncoded_merchants"] == ["starbucks"]
