#!/usr/bin/env python3
"""Generate data/playlists/public-domain-movies.m3u for Opal's Live TV.

Bundles a VOD catalog of public-domain feature films that Opal streams
directly over HTTP (archive.org) — no torrents, nothing stored on disk.
Registered as the `public-domain-movies` source in
src/services/iptv_sources.zig and mirrored in data/plugins-manifest.json;
the app fetches the playlist from this repository's raw GitHub URL.

Provenance (all legal, public-domain content):
  • Seed  — github.com/OnlineM3U/publicdomainm3u (hand-picked classics
            with curated posters; entries are re-grouped by decade).
  • Bulk  — archive.org "Feature Films" collection, top N items by
            downloads. For each item the metadata API is queried and the
            largest directly-playable mp4/webm/ogv derivative is chosen —
            the same selection rule Opal's own archive.org resolver
            backend uses (src/services/archive_pure.zig, pickBestVideoFile).

Subtitles: archive.org auto-generates machine (`asr`) SRT sidecars for
many items (~40% of the bulk cut). Each film that has one carries it as a
`subs="…"` EXTINF attribute (largest subtitled video wins — timing matches
the item's best-quality file); Opal's player selects it on FILE_LOADED.

Subtitles: archive.org auto-generates machine (`asr`) SRT sidecars for
many items (~40% of the bulk cut). Each film that has one carries it as a
`subs="…"` EXTINF attribute (largest subtitled video wins — timing matches
the item's best-quality file); Opal's player selects it on FILE_LOADED.

Usage:
    python3 scripts/generate_public_domain_movies.py [rows]   # default 500

Writes data/playlists/public-domain-movies.m3u relative to the repo root.
Only the Python standard library is required.
"""

from __future__ import annotations

import concurrent.futures as cf
import datetime as dt
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# ── Configuration ────────────────────────────────────────────────────────────

SEED_URL = "https://raw.githubusercontent.com/OnlineM3U/publicdomainm3u/main/movies.m3u"
SEARCH_URL = (
    "https://archive.org/advancedsearch.php"
    "?q=collection%3Afeature_films+AND+mediatype%3Amovies"
    "&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=year"
    "&sort%5B%5D=downloads+desc&rows={rows}&page=1&output=json"
)
METADATA_URL = "https://archive.org/metadata/{identifier}"
DEFAULT_ROWS = 500
WORKERS = 8
REQUEST_TIMEOUT = 30
MIN_FILE_BYTES = 2 * 1024 * 1024  # skip sub-2MB "video" files (intros, samples)
OUT_PATH = Path(__file__).resolve().parent.parent / "data" / "playlists" / "public-domain-movies.m3u"
USER_AGENT = "opal-public-domain-playlist-generator/1.0"

# Curation: keep the bundled catalog clean of exploitation titles. (Opal's
# ingest would merely NSFW-flag these; we prefer not to ship them at all.)
TITLE_BLOCKLIST = (
    "sex", "nudist", "nudism", "nude", "porn", "xxx", "horny", "smut", "erotic",
)

# Famous public-domain films whose downloads rank below the top-N cut; their
# archive.org identifiers are pinned so the bundled catalog always carries
# them. Verified against the feature_films collection.
ICONIC_IDENTIFIERS = (
    "metropolis-1927-bdrip-1080p-x-265-dts-hd-ma-5.1-d-0ct-0r-lew-sev",  # Metropolis (1927)
    "plan.-9.-from.-outer.-space.-1957",  # Plan 9 from Outer Space (1957)
    "dementia-13-1963_202312",  # Dementia 13 (1963)
)

# ── Small HTTP helper ────────────────────────────────────────────────────────


def http_get(url: str, timeout: int = REQUEST_TIMEOUT, retries: int = 2) -> str:
    """GET with backoff — archive.org throttles bursts with 429/503."""
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            if exc.code in (429, 503) and attempt < retries:
                time.sleep(3 * (attempt + 1))
                continue
            raise
        except Exception:
            if attempt < retries:
                time.sleep(2)
                continue
            raise
    raise RuntimeError(f"unreachable: {url}")


def url_alive(url: str) -> bool:
    """Cheap liveness probe (0-byte range request) for seed stream URLs.

    A 429 means archive.org is throttling us, NOT that the stream is dead —
    treat it as alive and let ingest-time health probing settle it later.
    """
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": USER_AGENT, "Range": "bytes=0-0"}
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status < 400
    except urllib.error.HTTPError as exc:
        return exc.code == 429
    except Exception:
        return False


# ── Title / year helpers ─────────────────────────────────────────────────────


def clean_title(raw: str) -> str:
    """Normalize an archive.org title into a safe EXTINF display name.

    Commas MUST be removed: Opal's playlist parser takes the channel name
    from everything after the LAST comma of the #EXTINF line, so a comma
    inside the title would truncate it (see iptv_playlist_pure.displayName).
    """
    title = re.sub(r"[\r\n]+", " ", raw)
    title = title.replace(", ", " – ").replace(",", " ")
    title = re.sub(r"\s+", " ", title).strip(" \t-–")
    return title[:150]


def find_year(text: str) -> int | None:
    m = re.search(r"\b((?:18|19|20)\d{2})\b", text)
    return int(m.group(1)) if m else None


def split_year(title: str, year: int | None) -> tuple[str, int | None]:
    """Extract a trailing "(YYYY)" / "- YYYY" from a title into the year.

    Archive items describe the same film variously as "Carnival of Souls",
    "Carnival of Souls (1962)" or "Carnival of Souls - 1962"; splitting the
    year out gives both a stable dedupe key and a uniform display name.
    """
    m = re.search(r"\s*\(((?:18|19|20)\d{2})\)\s*$", title)
    if m:
        return title[: m.start()].strip(), int(m.group(1))
    m = re.search(r"\s*[-\u2013]\s*((?:18|19|20)\d{2})\s*$", title)
    if m:
        return title[: m.start()].strip(), int(m.group(1))
    if not year:
        found = re.search(r"\b((?:18|19|20)\d{2})\b", title)
        if found:
            return title, int(found.group(1))
    return title, year


def norm_key(title: str, year: int | None) -> str:
    base = re.sub(r"[^a-z0-9]+", "", title.lower())
    base = re.sub(r"^charliechaplinss?", "", base)
    return f"{base}|{year or 0}"


def blocked(title: str) -> bool:
    low = title.lower()
    return any(word in low for word in TITLE_BLOCKLIST)


def decade_of(year: int | None) -> str:
    if not year:
        return "Misc"
    return f"{(year // 10) * 10}s"


# ── archive.org item resolution ──────────────────────────────────────────────


def pick_best_video(files: list[dict]) -> str | None:
    """Largest directly-playable video derivative, mp4 > webm > ogv.

    Mirrors archive_pure.zig pickBestVideoFile: the mp4 tier always wins,
    largest within its tier, so we never surface a low-quality derivative
    when a bigger playable one exists.
    """
    best: dict[str, tuple[str | None, int]] = {
        ".mp4": (None, 0), ".webm": (None, 0), ".ogv": (None, 0),
    }
    for f in files:
        name = f.get("name") or ""
        low = name.lower()
        try:
            size = int(str(f.get("size") or "0"))
        except ValueError:
            size = 0
        if size < MIN_FILE_BYTES:
            continue
        for ext in (".mp4", ".webm", ".ogv"):
            if low.endswith(ext) and size > best[ext][1]:
                best[ext] = (name, size)
    for ext in (".mp4", ".webm", ".ogv"):
        if best[ext][0]:
            return best[ext][0]
    return None


# Extensions that can sit under an archive.org `*.asr.srt` transcription.
SUB_VIDEO_EXTS = (".mp4", ".m4v", ".mkv", ".webm", ".ogv", ".avi", ".mpg", ".mpeg", ".ts")


def pick_best_subtitle(files: list[dict]) -> str | None:
    """ASR subtitle sidecar transcribed from the item's best subtitled video.

    archive.org names machine-generated SRTs after the video they came from —
    `NightOfTheLivingDead_DVD5.asr.srt` transcribes
    `NightOfTheLivingDead_DVD5.mp4`. The chosen video (largest mp4) and the
    subtitled video (often an older derivative) usually differ, so the rule is
    NOT stem-matching against the chosen video: prefer the sidecar whose OWN
    stem has the largest video on the item (best transcription, correct
    timing), tie-broken by the SRT's size. One film → one sidecar.
    """
    video_size_by_stem: dict[str, int] = {}
    for f in files:
        name = f.get("name") or ""
        low = name.lower()
        stem = None
        for ext in SUB_VIDEO_EXTS:
            if low.endswith(ext):
                stem = name[: -len(ext)]
                break
        if stem is None:
            continue
        try:
            size = int(str(f.get("size") or "0"))
        except ValueError:
            size = 0
        if size > video_size_by_stem.get(stem, 0):
            video_size_by_stem[stem] = size

    best: str | None = None
    best_rank = (0, 0)
    for f in files:
        name = f.get("name") or ""
        if not name.lower().endswith(".asr.srt"):
            continue
        stem = name[: -len(".asr.srt")]
        try:
            size = int(str(f.get("size") or "0"))
        except ValueError:
            size = 0
        rank = (video_size_by_stem.get(stem, 0), size)
        if rank > best_rank:
            best_rank = rank
            best = name
    return best


def resolve_item(identifier: str) -> dict | None:
    """Best direct-play URL + canonical title/year for an archive item."""
    try:
        meta = json.loads(http_get(METADATA_URL.format(identifier=identifier)))
    except Exception:
        return None
    name = pick_best_video(meta.get("files") or [])
    if not name:
        return None
    md = meta.get("metadata") or {}
    url = f"https://archive.org/download/{identifier}/{urllib.parse.quote(name)}"
    return {
        "url": url,
        "title": clean_title(str(md.get("title") or identifier)),
        "year": _year_from(md),
        "sub": sub_url_from_meta(identifier, meta),
    }


def fetch_sub_for(identifier: str) -> str | None:
    """Subtitle sidecar URL for an already-resolved (seed) archive item."""
    try:
        meta = json.loads(http_get(METADATA_URL.format(identifier=identifier)))
    except Exception:
        return None
    return sub_url_from_meta(identifier, meta)


def sub_url_from_meta(identifier: str, meta: dict) -> str | None:
    sub_name = pick_best_subtitle(meta.get("files") or [])
    if not sub_name:
        return None
    return f"https://archive.org/download/{identifier}/{urllib.parse.quote(sub_name, safe='/')}"


def _year_from(md: dict) -> int | None:
    for field in ("year", "date"):
        m = re.search(r"\b((?:18|19|20)\d{2})\b", str(md.get(field) or ""))
        if m:
            return int(m.group(1))
    return None


# ── Seed playlist (curated GitHub list) ──────────────────────────────────────


def parse_seed(text: str) -> list[dict]:
    entries: list[dict] = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if not line.startswith("#EXTINF"):
            continue
        url = ""
        for follow in lines[i + 1:]:
            candidate = follow.strip()
            if candidate and not candidate.startswith("#"):
                url = candidate
                break
        if not url or "archive.org/download/" not in url:
            continue
        name = line[line.rfind(",") + 1:].strip() if "," in line else ""
        logo_m = re.search(r'tvg-logo="([^"]*)"', line)
        title, year = split_year(clean_title(name), None)
        entries.append(
            {
                "title": title,
                "year": year,
                "logo": logo_m.group(1) if logo_m else "",
                "url": url,
                # The seed's genre groups are dropped in favour of uniform
                # decade grouping across the whole bundled catalog.
                "identifier": url.split("/download/", 1)[1].split("/", 1)[0],
                "sub": None,
            }
        )
    return entries


# ── Main ─────────────────────────────────────────────────────────────────────


def main() -> int:
    rows = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_ROWS
    today = dt.date.today().isoformat()

    # 1. Seed from the curated GitHub playlist (best-effort).
    seed: list[dict] = []
    try:
        candidates = parse_seed(http_get(SEED_URL))
        with cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
            alive = list(ex.map(url_alive, [c["url"] for c in candidates]))
        seed = [c for c, ok in zip(candidates, alive) if ok]
        print(f"seed: {len(seed)} live entries from OnlineM3U/publicdomainm3u")
        # Enrich seeds with their item's ASR subtitle sidecar (metadata fetch
        # per entry; the seed only carries stream URLs, never the files list).
        with cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
            subs = list(ex.map(fetch_sub_for, [c["identifier"] for c in seed]))
        for entry, sub in zip(seed, subs):
            entry["sub"] = sub
        print(f"seed subs: {sum(1 for s in subs if s)} of {len(seed)} entries")
    except Exception as exc:  # noqa: BLE001 — seed is optional
        print(f"warn: seed playlist unavailable ({exc}); continuing without it", file=sys.stderr)

    # 2. Bulk from the archive.org Feature Films collection (top `rows`),
    #    plus the pinned iconic films that sit outside that cut.
    docs = json.loads(http_get(SEARCH_URL.format(rows=rows)))["response"]["docs"]
    known_ids = {d.get("identifier") for d in docs}
    docs += [{"identifier": ident} for ident in ICONIC_IDENTIFIERS if ident not in known_ids]
    print(f"search: {len(docs)} candidate items (top {rows} + iconic boost)")

    items: list[dict] = []
    with cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futures = [
            (doc, ex.submit(resolve_item, doc.get("identifier") or ""))
            for doc in docs
            if doc.get("identifier")
        ]
        for doc, fut in futures:
            resolved = fut.result()
            if not resolved:
                continue
            title, year = split_year(
                clean_title(str(doc.get("title") or resolved["title"])),
                doc.get("year") or resolved["year"],
            )
            if not title or blocked(title):
                continue
            items.append(
                {
                    "title": title,
                    "year": year or find_year(title),
                    "logo": f"https://archive.org/services/img/{doc['identifier']}",
                    "url": resolved["url"],
                    "identifier": doc["identifier"],
                    "sub": resolved.get("sub"),
                }
            )
    print(f"resolved: {len(items)} playable items")

    # 3. Merge: seed entries win, then bulk entries deduped by archive
    #    identifier AND by normalized title+year.
    seen_ids = {e["identifier"] for e in seed}
    seen_keys = {norm_key(e["title"], e["year"]) for e in seed}
    merged = list(seed)
    for item in items:
        key = norm_key(item["title"], item["year"])
        if item["identifier"] in seen_ids or key in seen_keys:
            continue
        seen_ids.add(item["identifier"])
        seen_keys.add(key)
        merged.append(item)

    merged.sort(key=lambda e: (e["year"] or 9999, e["title"].lower()))

    # 4. Write the playlist.
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    header = (
        "#EXTM3U\n"
        "# Opal — Public Domain Movies (bundled VOD playlist)\n"
        "#\n"
        "# Public-domain feature films streamed DIRECTLY from archive.org over\n"
        "# HTTP: the Live TV player opens these URLs without downloading or\n"
        "# seeding anything. Films are grouped by decade (category filter).\n"
        "#\n"
        "# Provenance:\n"
        "#   seed — github.com/OnlineM3U/publicdomainm3u (curated classics)\n"
        f"#   bulk — archive.org 'Feature Films' collection, top {rows} by downloads\n"
        f"# Regenerated {today} — scripts/generate_public_domain_movies.py\n"
        "# Film content is public domain; streams are served by archive.org.\n"
    )
    lines = [header]
    with_subs = 0
    for e in merged:
        logo = f' tvg-logo="{e["logo"]}"' if e["logo"] else ""
        sub = f' subs="{e["sub"]}"' if e.get("sub") else ""
        if sub:
            with_subs += 1
        year = f" ({e['year']})" if e["year"] else ""
        lines.append(
            f'#EXTINF:-1{logo}{sub} group-title="{decade_of(e["year"])}",{e["title"]}{year}\n'
            f'{e["url"]}\n'
        )
    OUT_PATH.write_text("".join(lines), encoding="utf-8")

    decades: dict[str, int] = {}
    for e in merged:
        decades[decade_of(e["year"])] = decades.get(decade_of(e["year"]), 0) + 1
    print(f"wrote {OUT_PATH} — {len(merged)} films ({with_subs} with ASR subtitles)")
    for decade in sorted(decades):
        print(f"  {decade}: {decades[decade]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
