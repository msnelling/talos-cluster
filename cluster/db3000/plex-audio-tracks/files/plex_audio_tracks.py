#!/usr/bin/env python3
"""Re-point Plex audio track selection away from TrueHD.

The chain is Plex -> Apple TV -> Sonos Arc Ultra. tvOS cannot decode TrueHD,
so a TrueHD selection either transcodes on the cluster or falls back to a
lossy 5.1 track with no height. E-AC-3 with Atmos is the only format that
reaches the Arc Ultra with height intact.

Every movie and show library is inspected on each run. Selection is stored per
Plex account (the token's owner) in Plex's database; no media file is touched.
A manual re-selection of TrueHD is reverted on the next run — for this chain
that is never the right track.

Environment:
  PLEX_URL      e.g. http://plex.db3000.svc:32400
  PLEX_TOKEN    account token, sent as the X-Plex-Token header
  APPLY         "true" to change selections; anything else is a dry run
  MAX_CHANGES   refuse to apply a plan larger than this (default 50)
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

# Plex rejects an over-long URL, and a show library runs to thousands of keys.
BATCH = 200
TIMEOUT = 60
EXCLUDE_RE = re.compile(r"commentar|descri|descry|isolated|karaoke|sing-?along")
# Episodes must be requested explicitly; a show section lists shows, which
# carry no Media/Part.
SECTION_QUERY = {"movie": "", "show": "?type=4"}


class PlexError(Exception):
    pass


def plex(path, method="GET"):
    req = urllib.request.Request(
        PLEX_URL + path,
        method=method,
        headers={"X-Plex-Token": PLEX_TOKEN, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        raise PlexError(f"{method} {path}: HTTP {e.code}") from None
    except urllib.error.URLError as e:
        raise PlexError(f"{method} {path}: {e.reason}") from None


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
            return 3 if "atmos" in label(s) else 2
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
                audio = [s for s in part.get("Stream", []) if s.get("streamType") == 2]
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
    plan = build_plan(fetch_items(keys))
    print_plan(plan)

    counts = {a: sum(1 for r in plan if r["action"] == a) for a in ("ATMOS", "MOVE", "SKIP")}
    print(f"Inspected {len(keys)} items; {len(plan)} have TrueHD selected.")
    print(f"  ATMOS {counts['ATMOS']}  — gains height on the Arc Ultra (E-AC-3 JOC)")
    print(f"  MOVE  {counts['MOVE']}  — no height either way, but direct plays instead of transcoding")
    print(f"  SKIP  {counts['SKIP']}  — no playable alternative track, left on TrueHD")

    todo = pending(plan)
    if not APPLY:
        print("\nDry run — nothing changed. Set APPLY=true to commit.")
        return
    if not todo:
        print("\nNothing to apply.")
        return
    # A runaway plan is more likely to mean Plex changed shape than that the
    # library did, and this runs unattended.
    if len(todo) > MAX_CHANGES:
        sys.exit(f"\nPlan has {len(todo)} changes, above MAX_CHANGES={MAX_CHANGES} — applying nothing")

    print("\nApplying...")
    failed = apply(todo)
    print(f"  {len(todo) - failed} applied, {failed} failed")

    # A 2xx does not prove the selection moved, so re-read the items that
    # changed and rebuild their rows. Anything still pending means Plex
    # accepted a PUT without acting on it.
    print("Verifying...")
    changed = sorted({r["key"] for r in todo})
    left = pending(build_plan(fetch_items(changed)))
    if left:
        for r in left:
            print(f"  {r['title']} ({r['part']}:{r['stream']})", file=sys.stderr)
        sys.exit(f"{len(left)} selection(s) did not take")
    if failed:
        sys.exit(f"{failed} PUT(s) failed")
    print("  all selections confirmed")
    print("Done. Selection is per Plex account — other household accounts are unchanged.")


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


if __name__ == "__main__":
    try:
        main()
    except PlexError as e:
        sys.exit(str(e))
