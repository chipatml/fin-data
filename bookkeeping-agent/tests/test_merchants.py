from bookkeeping_agent.merchants import normalize_merchant, service_class


def test_strips_processor_prefix_and_store_number():
    assert normalize_merchant("SQ *STARBUCKS #142") == "starbucks"
    assert normalize_merchant("TST* Pizza Place") == "pizza place"
    assert normalize_merchant("PAYPAL *STEAM") == "steam"


def test_strips_tld_and_lowercases():
    assert normalize_merchant("NETFLIX.COM") == "netflix"
    assert normalize_merchant("Hulu") == "hulu"


def test_variants_collapse_to_same_key():
    assert normalize_merchant("SQ *STARBUCKS #142") == normalize_merchant("Starbucks")


def test_empty_and_none():
    assert normalize_merchant(None) == ""
    assert normalize_merchant("") == ""


def test_service_class_grouping():
    assert service_class("netflix") == "streaming_video"
    assert service_class("hulu") == "streaming_video"
    assert service_class("spotify") == "music"
    assert service_class("starbucks") is None
