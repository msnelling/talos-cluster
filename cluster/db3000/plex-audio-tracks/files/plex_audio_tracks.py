#!/usr/bin/env python3
"""Keep Plex playback off TrueHD, and get files that cannot be fixed replaced.

The chain is Plex -> Apple TV -> Sonos Arc Ultra. tvOS cannot decode TrueHD,
so a TrueHD selection either transcodes on the cluster or falls back to a
lossy 5.1 track with no height. E-AC-3 with Atmos is the only format that
reaches the Arc Ultra with height intact.

Three phases, each run against every movie and show library:

  1. Selection — re-point any TrueHD-selected part at its best E-AC-3/AC-3
     track. Selection is stored per Plex account (the token's owner); no
     media file is touched. A manual re-selection of TrueHD is reverted on
     the next run — for this chain that is never the right track.
  2. Report — list every file carrying a lossless object-audio track
     (TrueHD or DTS:X) with no E-AC-3 Atmos alternative. Selection cannot
     give those height; only a different file can.
  3. Radarr — films from the report that carry the opt-in tag are moved onto
     the Atmos quality profile and searched once. Nothing is moved without
     the tag: tagging in Radarr is the decision to trade the disc remux for
     a WEB-DL. Series are report-only because Sonarr profiles are
     per-series, and a series usually has more files than the report lists.

A Radarr failure never undoes or masks Plex work already applied; every
phase runs, and the exit status reflects all of them.

Environment:
  PLEX_URL        e.g. http://plex.db3000.svc:32400
  PLEX_TOKEN      account token, sent as the X-Plex-Token header
  APPLY           "true" to change selections and move films; else dry run
  MAX_CHANGES     refuse a selection plan larger than this (default 50)
  RADARR_URL      e.g. http://radarr.db3000.svc/radarr; unset skips phase 3
  RADARR_API_KEY  sent as the X-Api-Key header
  RADARR_PROFILE  quality profile to move tagged films onto
  RADARR_TAG      tag that opts a film in (created if missing)
  RADARR_SEARCH   "true" to search for each newly moved film (default true)
  MAX_MOVES       move at most this many films per run (default 10)
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

PLEX_URL = os.environ["PLEX_URL"].rstrip("/")
PLEX_TOKEN = os.environ["PLEX_TOKEN"]
APPLY = os.environ.get("APPLY", "false").lower() == "true"
MAX_CHANGES = int(os.environ.get("MAX_CHANGES", "50"))
RADARR_URL = os.environ.get("RADARR_URL", "").rstrip("/")
RADARR_API_KEY = os.environ.get("RADARR_API_KEY", "")
RADARR_PROFILE = os.environ.get("RADARR_PROFILE", "")
RADARR_TAG = os.environ.get("RADARR_TAG", "atmos-upgrade")
RADARR_SEARCH = os.environ.get("RADARR_SEARCH", "true").lower() == "true"
MAX_MOVES = int(os.environ.get("MAX_MOVES", "10"))

# Plex rejects an over-long URL, and a show library runs to thousands of keys.
# It also analyses any unanalysed item before answering a metadata request,
# at roughly half a second each, so a batch must fit inside TIMEOUT even when
# every item in it is unanalysed.
BATCH = 50
TIMEOUT = 300
EXCLUDE_RE = re.compile(r"commentar|descri|descry|isolated|karaoke|sing-?along")
# Episodes must be requested explicitly; a show section lists shows, which
# carry no Media/Part.
SECTION_QUERY = {"movie": "", "show": "?type=4"}


class PlexError(Exception):
    pass


class RadarrError(Exception):
    pass


def request(url, headers, method, body, error):
    data = json.dumps(body).encode() if body is not None else None
    if data:
        headers = {**headers, "Content-Type": "application/json"}
    req = urllib.request.Request(url, method=method, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            payload = resp.read()
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as e:
        raise error(f"{method} {url}: HTTP {e.code}") from None
    except urllib.error.URLError as e:
        raise error(f"{method} {url}: {e.reason}") from None


def plex(path, method="GET"):
    headers = {"X-Plex-Token": PLEX_TOKEN, "Accept": "application/json"}
    return request(PLEX_URL + path, headers, method, None, PlexError)


def radarr(path, method="GET", body=None):
    headers = {"X-Api-Key": RADARR_API_KEY, "Accept": "application/json"}
    return request(RADARR_URL + "/api/v3" + path, headers, method, body, RadarrError)


def fetch_keys(section):
    query = SECTION_QUERY[section["type"]]
    listing = plex(f"/library/sections/{section['key']}/all{query}")
    return [m["ratingKey"] for m in listing["MediaContainer"].get("Metadata", [])]


def fetch_items(keys):
    """Batched metadata with stream detail. Refuses a short read, which would
    otherwise look exactly like "nothing needs changing"."""
    items = []
    for i in range(0, len(keys), BATCH):
        chunk = keys[i : i + BATCH]
        body = plex(f"/library/metadata/{','.join(chunk)}")
        items.extend(body["MediaContainer"].get("Metadata", []))
    if len(items) != len(keys):
        sys.exit(f"Read {len(items)} of {len(keys)} items — refusing to plan on partial data")
    return items


def label(stream):
    return " ".join(
        stream.get(k) or "" for k in ("extendedDisplayTitle", "displayTitle", "title")
    ).lower()


def audio_streams(part):
    return [s for s in part.get("Stream", []) if s.get("streamType") == 2]


def is_atmos(stream):
    return stream.get("codec") == "eac3" and "atmos" in label(stream)


def object_codec(stream):
    """The lossless object-audio format a stream carries, or None."""
    if stream.get("codec") == "truehd":
        return "TrueHD"
    if stream.get("codec") == "dca" and re.search(r"dts[:\- ]?x", label(stream)):
        return "DTS:X"
    return None


def human(size):
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1000:
            return f"{size:.0f} {unit}"
        size /= 1000
    return f"{size:.2f} TB"


def best_candidate(audio, selected):
    """A filter chain, deliberately not a score:
      - candidates are the audio streams that are not currently selected
      - drop commentary / audio-description / isolated-score tracks
      - drop languages differing from the selected track (keeps dubs out)
      - keep only E-AC-3 and AC-3; DTS, FLAC, PCM, AAC and the rest are never
        candidates, the chain cannot decode them either
      - rank eac3+atmos > eac3 > ac3, then by channel count

    Atmos outranks channel count on purpose: a 5.1 E-AC-3 JOC track carries
    height to the Arc Ultra, a 7.1 E-AC-3 track without Atmos does not.
    """
    want_lang = selected.get("languageCode") or ""

    def rank(s):
        if s["codec"] == "eac3":
            return 3 if is_atmos(s) else 2
        return 1

    cands = [
        s
        for s in audio
        if not s.get("selected")
        and not EXCLUDE_RE.search(label(s))
        and (
            (s.get("languageCode") or "") == want_lang
            if want_lang
            else (s.get("languageCode") or "") in ("", "eng")
        )
        and s.get("codec") in ("eac3", "ac3")
    ]
    if not cands:
        return None
    best = max(cands, key=lambda s: (rank(s), s.get("channels") or 0))
    return best, rank(best)


def build_plan(items):
    """One row per part whose selected audio track is TrueHD."""
    plan = []
    for m in items:
        for media in m.get("Media", []):
            for part in media.get("Part", []):
                audio = audio_streams(part)
                selected = next((s for s in audio if s.get("selected")), None)
                if not selected or selected.get("codec") != "truehd":
                    continue
                row = {"title": m.get("title", ""), "key": m["ratingKey"], "part": part["id"]}
                found = best_candidate(audio, selected)
                if found is None:
                    row.update(action="SKIP", track="no usable E-AC-3/AC-3 track")
                else:
                    best, r = found
                    row.update(
                        action="ATMOS" if r == 3 else "MOVE",
                        stream=best["id"],
                        track=best.get("extendedDisplayTitle")
                        or best.get("displayTitle")
                        or best["codec"],
                    )
                plan.append(row)
    return sorted(plan, key=lambda r: r["title"])


def print_plan(plan):
    print()
    print(f"{'ACTION':<6} {'TITLE':<46} NEW TRACK")
    for r in plan:
        print(f"{r['action']:<6} {r['title'][:46]:<46} {r['track']}")
    print()


def pending(plan):
    return [r for r in plan if r["action"] in ("ATMOS", "MOVE")]


def select_tracks(items):
    """Phase 1. Returns an error message, or None."""
    plan = build_plan(items)
    print_plan(plan)

    counts = {a: sum(1 for r in plan if r["action"] == a) for a in ("ATMOS", "MOVE", "SKIP")}
    print(f"Inspected {len(items)} items; {len(plan)} have TrueHD selected.")
    print(f"  ATMOS {counts['ATMOS']}  — gains height on the Arc Ultra (E-AC-3 JOC)")
    print(f"  MOVE  {counts['MOVE']}  — no height either way, but direct plays instead of transcoding")
    print(f"  SKIP  {counts['SKIP']}  — no playable alternative track, left on TrueHD")

    todo = pending(plan)
    if not APPLY:
        print("\nDry run — nothing changed. Set APPLY=true to commit.")
        return None
    if not todo:
        print("\nNothing to apply.")
        return None
    # A runaway plan is more likely to mean Plex changed shape than that the
    # library did, and this runs unattended.
    if len(todo) > MAX_CHANGES:
        return f"Plan has {len(todo)} changes, above MAX_CHANGES={MAX_CHANGES} — applied nothing"

    print("\nApplying...")
    failed = apply(todo)
    print(f"  {len(todo) - failed} applied, {failed} failed")

    # A 2xx does not prove the selection moved, so re-read the items that
    # changed and rebuild their rows. Anything still pending means Plex
    # accepted a PUT without acting on it.
    print("Verifying...")
    changed = sorted({r["key"] for r in todo})
    left = pending(build_plan(fetch_items(changed)))
    for r in left:
        print(f"  {r['title']} ({r['part']}:{r['stream']})", file=sys.stderr)
    print("  all selections confirmed" if not left else f"  {len(left)} did not take")
    print("Selection is per Plex account — other household accounts are unchanged.")
    if left:
        return f"{len(left)} selection(s) did not take"
    if failed:
        return f"{failed} PUT(s) failed"
    return None


def apply(todo):
    """PUT each selection, continuing past failures so one bad item does not
    block the rest. Returns the failure count; the caller decides the exit."""
    # allParts is deliberately not set: parts are iterated explicitly, so
    # letting Plex propagate one part's selection to its siblings would fight
    # the plan on multi-part items.
    failed = 0
    for r in todo:
        try:
            plex(f"/library/parts/{r['part']}?{urllib.parse.urlencode({'audioStreamID': r['stream']})}", "PUT")
        except PlexError as e:
            print(f"  {r['title']} ({r['part']}:{r['stream']}): {e}", file=sys.stderr)
            failed += 1
    return failed


def needs_replacement(items):
    """Phase 2. One row per file with TrueHD or DTS:X and no E-AC-3 Atmos.

    Files with no object audio at all are deliberately out of scope: nothing
    says an Atmos mix exists for them, and listing them would mean
    "re-download the library".
    """
    rows = []
    for m in items:
        for media in m.get("Media", []):
            parts = media.get("Part", [])
            audio = [s for p in parts for s in audio_streams(p)]
            codecs = sorted({c for s in audio if (c := object_codec(s))})
            if not codecs or any(is_atmos(s) for s in audio):
                continue
            # The year tells a remake apart from its original in the report.
            title = m.get("title", "")
            if m.get("type") == "movie" and m.get("year"):
                title = f"{title} ({m['year']})"
            rows.append(
                {
                    "type": m.get("type"),
                    "title": title,
                    "show": m.get("grandparentTitle", ""),
                    "codec": "/".join(codecs),
                    "file": parts[0].get("file", "") if parts else "",
                    "size": sum(p.get("size") or 0 for p in parts),
                }
            )
    return sorted(rows, key=lambda r: (r["show"], r["title"]))


def print_report(rows):
    films = [r for r in rows if r["type"] == "movie"]
    episodes = [r for r in rows if r["type"] == "episode"]
    print()
    print("Files with TrueHD/DTS:X and no E-AC-3 Atmos — only a different file gives these height:")
    print(f"  Films     {len(films):>3}  {human(sum(r['size'] for r in films))}")
    print(f"  Episodes  {len(episodes):>3}  {human(sum(r['size'] for r in episodes))}")
    shows = {}
    for r in episodes:
        n, size = shows.get(r["show"], (0, 0))
        shows[r["show"]] = (n + 1, size + r["size"])
    for show, (n, size) in sorted(shows.items()):
        print(f"    {show[:44]:<44} {n:>3} episodes  {human(size):>9}")
    if episodes:
        print("  Episodes are report-only: Sonarr profiles are per-series, so moving a series")
        print("  puts every one of its files up for replacement, not just the ones listed.")
    return films


def radarr_phase(films):
    """Phase 3. Returns an error message, or None."""
    profiles = {p["name"]: p["id"] for p in radarr("/qualityprofile")}
    if RADARR_PROFILE not in profiles:
        return f"Radarr has no quality profile named {RADARR_PROFILE!r}"
    profile_id = profiles[RADARR_PROFILE]
    tag_id = next((t["id"] for t in radarr("/tag") if t["label"] == RADARR_TAG), None)
    if tag_id is None and APPLY:
        # Created empty so the tag is offered in Radarr's UI before anything
        # carries it. Nothing is moved on this run.
        tag_id = radarr("/tag", "POST", {"label": RADARR_TAG})["id"]
        print(f"\nCreated Radarr tag {RADARR_TAG!r} — tag a film with it to opt it in.")

    by_path = {m["movieFile"]["path"]: m for m in radarr("/movie") if m.get("hasFile")}
    groups = {"moving": [], "waiting": [], "untagged": [], "untracked": []}
    for r in films:
        m = by_path.get(r["file"])
        if m is None:
            group = "untracked"
        elif m["qualityProfileId"] == profile_id:
            group = "waiting"
        elif tag_id in m["tags"]:
            group = "moving"
        else:
            group = "untagged"
        groups[group].append((r, m))

    print(f"\n{'STATUS':<9} {'FILM':<44} {'SIZE':>9}  AUDIO")
    for group, entries in groups.items():
        for r, _ in entries:
            print(f"{group:<9} {r['title'][:44]:<44} {human(r['size']):>9}  {r['codec']}")
    print()
    searched = " and searched once" if RADARR_SEARCH else ""
    print(f"  moving    {len(groups['moving']):>3}  — tagged {RADARR_TAG!r}; moved to {RADARR_PROFILE!r}{searched}")
    print(f"  waiting   {len(groups['waiting']):>3}  — on {RADARR_PROFILE!r}; Radarr grabs a DD+ Atmos WEB-DL when one appears")
    print(f"  untagged  {len(groups['untagged']):>3}  — tag {RADARR_TAG!r} in Radarr to opt a film in")
    print(f"  untracked {len(groups['untracked']):>3}  — file not in Radarr (a second copy Plex sees), nothing will replace it")

    moves = [m for _, m in groups["moving"]]
    if not moves:
        return None
    if len(moves) > MAX_MOVES:
        print(f"  moving only the first {MAX_MOVES} this run (MAX_MOVES)")
        moves = moves[:MAX_MOVES]
    ids = [m["id"] for m in moves]
    if not APPLY:
        print(f"\nDry run — would move {len(ids)} film(s) to {RADARR_PROFILE!r}.")
        return None
    radarr("/movie/editor", "PUT", {"movieIds": ids, "qualityProfileId": profile_id})
    print(f"\nMoved {len(ids)} film(s) to {RADARR_PROFILE!r}.")
    # Searched on the transition only; afterwards the RSS sync picks up new
    # releases without hammering the indexers every night.
    if RADARR_SEARCH:
        radarr("/command", "POST", {"name": "MoviesSearch", "movieIds": ids})
        print("  search queued")
    return None


def main():
    sections = [
        s
        for s in plex("/library/sections")["MediaContainer"].get("Directory", [])
        if s.get("type") in SECTION_QUERY
    ]
    if not sections:
        sys.exit("No movie or show libraries found")

    keys = []
    for s in sections:
        section_keys = fetch_keys(s)
        print(f"Library '{s['title']}' ({s['type']}): {len(section_keys)} items")
        keys.extend(section_keys)
    if not keys:
        sys.exit("Libraries returned no items")

    print("Reading audio streams...")
    items = fetch_items(keys)

    errors = [select_tracks(items)]
    films = print_report(needs_replacement(items))
    if RADARR_URL:
        try:
            errors.append(radarr_phase(films))
        except RadarrError as e:
            errors.append(str(e))

    errors = [e for e in errors if e]
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    try:
        main()
    except PlexError as e:
        sys.exit(str(e))
