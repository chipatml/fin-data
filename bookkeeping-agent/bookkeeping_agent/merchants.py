"""Merchant-name normalization and service-class grouping.

Shared by the category store (stable keys for merchant -> category memory) and
the recurring detector (grouping charges from the same vendor across pulls).
Pure functions, no third-party deps, so they are cheap to unit-test.
"""

from __future__ import annotations

import re

# Payment-processor prefixes Plaid leaves on the raw name, e.g. "SQ *STARBUCKS",
# "TST* PIZZA", "PAYPAL *STEAM", "SP GREENHOUSE". The token must be followed by a
# real separator (a "*" run or whitespace) so it only strips a standalone prefix,
# never a word that merely starts with those letters ("Spotify", "Postmates").
_PROCESSOR_PREFIX = re.compile(
    r"^\s*(sq|tst|py|pp|ppl|paypal|sp|pos|dd|ext|ci|chk|pmt)(?:\s*\*+\s*|\s+)",
    re.IGNORECASE,
)
# A leading "PROCESSOR *" of any short token followed by a star.
_STAR_PREFIX = re.compile(r"^\s*[a-z0-9]{1,6}\s*\*+\s*", re.IGNORECASE)
# Trailing store / location numbers: "#1234", " 00456", "STORE 12".
_TRAILING_STORE = re.compile(r"(#\s*\d+|\bstore\s+\d+|\s+\d{3,})\s*$", re.IGNORECASE)
_TLD = re.compile(r"\.(com|net|org|co|io|shop)\b", re.IGNORECASE)
_NON_ALNUM = re.compile(r"[^a-z0-9]+")


def normalize_merchant(name: str | None) -> str:
    """Collapse a raw merchant/description string to a stable lowercase key.

    "SQ *STARBUCKS #123" -> "starbucks", "NETFLIX.COM" -> "netflix",
    "AMZN Mktp US" -> "amzn mktp us" (aggregators stay distinguishable).
    Returns "" when nothing usable remains.
    """
    if not name:
        return ""
    s = str(name).strip()
    s = _PROCESSOR_PREFIX.sub("", s)
    # A second pass catches a remaining generic "XXX *" processor tag.
    s = _STAR_PREFIX.sub("", s)
    s = _TLD.sub("", s)
    s = _TRAILING_STORE.sub("", s)
    s = _NON_ALNUM.sub(" ", s.lower()).strip()
    s = re.sub(r"\s+", " ", s)
    return s


# Merchant substrings that indicate a shared service class, so the recurring
# detector can flag duplicated/overlapping subscriptions (e.g. 3 streaming
# services). Matched against the normalized key.
SERVICE_CLASSES: dict[str, list[str]] = {
    "streaming_video": [
        "netflix", "hulu", "max", "hbo", "disney", "peacock", "paramount",
        "apple tv", "youtube premium", "youtube tv", "sling", "fubo",
    ],
    "music": [
        "spotify", "apple music", "tidal", "pandora", "youtube music", "deezer",
    ],
    "cloud_storage": [
        "dropbox", "icloud", "google one", "google storage", "onedrive", "box",
    ],
    "news": [
        "nyt", "new york times", "wsj", "wall street journal", "the athletic",
        "washington post", "economist", "medium",
    ],
    "fitness": [
        "peloton", "classpass", "planet fitness", "equinox", "crunch", "strava",
    ],
    "ai_tools": [
        "openai", "chatgpt", "anthropic", "claude", "perplexity", "midjourney",
        "github copilot",
    ],
}


def service_class(normalized_merchant: str) -> str | None:
    """Return the service-class label for a normalized merchant, or None."""
    if not normalized_merchant:
        return None
    for label, needles in SERVICE_CLASSES.items():
        for needle in needles:
            if needle in normalized_merchant:
                return label
    return None
