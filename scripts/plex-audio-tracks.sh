#!/usr/bin/env bash
# shellcheck shell=bash
# Re-point Plex audio track selection away from TrueHD.
#
# The chain is Plex -> Apple TV -> Sonos Arc Ultra. tvOS cannot decode TrueHD,
# so a TrueHD selection either transcodes on the cluster or falls back to a
# lossy 5.1 track with no height. E-AC-3 with Atmos is the only format that
# reaches the Arc Ultra with height intact.
#
# Selection is stored per Plex account (the token's owner) in Plex's database.
# No media file is touched.
#
# Usage: scripts/plex-audio-tracks.sh [--apply]
#        PLEX_SECTION=2 scripts/plex-audio-tracks.sh   # a different library
#        Without --apply it prints the plan and changes nothing.

set -euo pipefail

readonly NAMESPACE="db3000"
readonly SECTION="${PLEX_SECTION:-1}"
readonly EXCLUDE_RE='commentar|descri|descry|isolated|karaoke|sing-?along'
# Plex rejects an over-long URL, and a show library runs to thousands of keys.
readonly BATCH=200

APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

# items[*] rather than items[0]: with no match, items[0] fails the jsonpath
# template and set -e kills the script before the friendly message below.
POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=plex \
  --field-selector status.phase=Running \
  -o jsonpath='{.items[*].metadata.name}' | awk '{print $1}')
if [ -z "$POD" ]; then
  echo "No running Plex pod in $NAMESPACE" >&2
  exit 1
fi

# Read inside the pod so the token never reaches this host's process table.
# Spliced in as a double-quoted prefix to an otherwise single-quoted remote
# script, so nothing meant for the remote shell needs backslash-escaping.
# shellcheck disable=SC2016  # expands in the remote shell, not this one
readonly REMOTE_TOKEN='
  prefs=$(find /config -name Preferences.xml 2>/dev/null | head -1)
  tok=$(sed -n "s/.*PlexOnlineToken=\"\([^\"]*\)\".*/\1/p" "$prefs")
'

# plex_get <path> — path must end in "?" or "&"; the token is appended.
plex_get() {
  # shellcheck disable=SC2016  # single-quoted on purpose: remote-side expansion
  kubectl exec -n "$NAMESPACE" "$POD" -- sh -c "$REMOTE_TOKEN"'
    curl -sSf -H "Accept: application/json" \
      "http://localhost:32400${1}X-Plex-Token=$tok"
  ' _ "$1"
}

# A show section lists shows, which carry no Media/Part; only episodes do.
# Without this the script would inspect 52 shows, find nothing, and report a
# confident zero.
section_query() {
  local type
  type=$(plex_get "/library/sections?" \
    | jq -r --arg s "$SECTION" '.MediaContainer.Directory[]?
        | select(.key == $s) | .type')
  case "$type" in
    movie) echo "/library/sections/$SECTION/all?" ;;
    show)  echo "/library/sections/$SECTION/all?type=4&" ;;
    "")    echo "Section $SECTION does not exist" >&2; return 1 ;;
    *)     echo "Section $SECTION is type '$type', which has no audio" >&2; return 1 ;;
  esac
}

# fetch_detail <keys...>
# One batched request per BATCH keys. The section listing omits stream detail,
# but /library/metadata/<id,id,...> returns it for many items at once, which is
# two requests here instead of one per item.
fetch_detail() {
  local chunk
  while read -r chunk; do
    [ -n "$chunk" ] || continue
    plex_get "/library/metadata/$chunk?"
  done < <(xargs -n "$BATCH" <<<"$1" | tr ' ' ',')
}

# build_plan reads one or more MediaContainer documents on stdin.
#
# A filter chain, deliberately not a score. Each step is an independent
# predicate, so only the final sort is order-sensitive:
#   - candidates are the audio streams that are not currently selected
#   - drop commentary / audio-description / isolated-score tracks
#   - drop languages differing from the selected track (keeps Russian dubs out)
#   - keep only E-AC-3 and AC-3, so DTS, FLAC, PCM, AAC and the rest are never
#     candidates — the chain cannot decode them either
#   - rank eac3+atmos > eac3 > ac3, then by channel count
#
# Atmos outranks channel count on purpose: a 5.1 E-AC-3 JOC track carries
# height to the Arc Ultra, a 7.1 E-AC-3 track without Atmos does not.
build_plan() {
  jq -rn --arg ex "$EXCLUDE_RE" '
    [ inputs.MediaContainer.Metadata[]?
      | . as $m
      | .Media[]?.Part[]?
      | . as $p
      | [ .Stream[]?
          | select(.streamType == 2)
          | . + { label: ( ( (.extendedDisplayTitle // "") + " "
                           + (.displayTitle // "") + " "
                           + (.title // "") ) | ascii_downcase ) } ] as $auds
      | ( $auds | map(select(.selected == true)) | first ) as $sel
      | select($sel != null and $sel.codec == "truehd")
      | ( $auds
          | map(select(.selected != true))
          | map(select(.label | test($ex) | not))
          | map(select(
              if ($sel.languageCode // "") != "" then
                (.languageCode // "") == $sel.languageCode
              else
                ((.languageCode // "") == "") or ((.languageCode // "") == "eng")
              end ))
          | map(select(.codec == "eac3" or .codec == "ac3"))
          | map(. + { rank:
              ( if .codec == "eac3" and (.label | test("atmos")) then 3
                elif .codec == "eac3" then 2
                else 1 end ) })
          | sort_by(.rank, (.channels // 0))
          | reverse ) as $cands
      | { title: $m.title, key: $m.ratingKey, partId: $p.id,
          cand: ($cands | first) } ]
    | sort_by(.title)
    | .[]
    | if .cand == null then
        [ "SKIP", .title, "-", .key, "no usable E-AC-3/AC-3 track" ] | @tsv
      else
        [ (if .cand.rank == 3 then "ATMOS" else "MOVE" end),
          .title, "\(.partId):\(.cand.id)", .key,
          (.cand.extendedDisplayTitle // .cand.displayTitle // .cand.codec) ] | @tsv
      end
  '
}

# read_detail <keys> — fetch and refuse to continue on a short read, which
# would otherwise look exactly like "nothing needs changing".
read_detail() {
  local keys="$1" detail want got
  detail=$(fetch_detail "$keys")
  want=$(wc -w <<<"$keys" | tr -d ' ')
  got=$(jq -n '[inputs.MediaContainer.Metadata[]?] | length' <<<"$detail")
  if [ "$got" -ne "$want" ]; then
    echo "Read $got of $want items — refusing to plan on partial data" >&2
    return 1
  fi
  printf '%s' "$detail"
}

echo "Plex pod: $POD"
query=$(section_query)
echo "Fetching library section ${SECTION}..."
keys=$(plex_get "$query" | jq -r '.MediaContainer.Metadata[]?.ratingKey' | tr '\n' ' ')
keys=${keys% }
if [ -z "$keys" ]; then
  echo "Section $SECTION returned no items" >&2
  exit 1
fi
n_keys=$(wc -w <<<"$keys" | tr -d ' ')
echo "  $n_keys items"

echo "Reading audio streams..."
plan=$(read_detail "$keys" | build_plan)

read -r atmos moves skips < <(awk -F'\t' '
  $1 == "ATMOS" { a++ } $1 == "MOVE" { m++ } $1 == "SKIP" { s++ }
  END { print a+0, m+0, s+0 }' <<<"$plan")

echo
# awk, not read: IFS=$'\t' treats tab as whitespace and collapses the empty
# fields on SKIP rows, shifting every column after them.
awk -F'\t' 'BEGIN { printf "%-6s %-46s %s\n", "ACTION", "TITLE", "NEW TRACK" }
  NF { printf "%-6s %-46s %s\n", $1, substr($2, 1, 46), $5 }' <<<"$plan"
echo
echo "Inspected $n_keys items; $((atmos + moves + skips)) have TrueHD selected."
echo "  ATMOS $atmos  — gains height on the Arc Ultra (E-AC-3 JOC)"
echo "  MOVE  $moves  — no height either way, but direct plays instead of transcoding"
echo "  SKIP  $skips  — no playable alternative track, left on TrueHD"

if [ "$APPLY" != true ]; then
  echo
  echo "Dry run — nothing changed. Re-run with --apply to commit."
  exit 0
fi

if [ "$((atmos + moves))" -eq 0 ]; then
  echo
  echo "Nothing to apply."
  exit 0
fi

echo
echo "Applying..."
# allParts is deliberately not set: this iterates parts explicitly, so letting
# Plex propagate one part's selection to its siblings would fight the plan on
# multi-part items.
# shellcheck disable=SC2016  # single-quoted on purpose: remote-side expansion
awk -F'\t' '$1 == "MOVE" || $1 == "ATMOS" { print $3 }' <<<"$plan" \
  | kubectl exec -n "$NAMESPACE" -i "$POD" -- sh -c "$REMOTE_TOKEN"'
      ok=0; failed=0
      while IFS=: read -r part stream; do
        [ -n "$part" ] || continue
        code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
          "http://localhost:32400/library/parts/$part?audioStreamID=$stream&X-Plex-Token=$tok")
        case "$code" in
          2*) ok=$((ok+1)) ;;
          *)  echo "  part $part -> stream $stream failed (http $code)" >&2
              failed=$((failed+1)) ;;
        esac
      done
      echo "  $ok applied, $failed failed"
      [ "$failed" -eq 0 ]
    '

# A 2xx does not prove the selection moved, so re-read the items that changed
# and rebuild their rows. Anything still pending means Plex accepted a PUT
# without acting on it.
echo "Verifying..."
changed=$(awk -F'\t' '$1 == "MOVE" || $1 == "ATMOS" { print $4 }' <<<"$plan" | sort -u | tr '\n' ' ')
left=$(read_detail "${changed% }" | build_plan \
  | awk -F'\t' '$1 == "MOVE" || $1 == "ATMOS"')
if [ -n "$left" ]; then
  echo "$(wc -l <<<"$left" | tr -d ' ') selection(s) did not take:" >&2
  awk -F'\t' '{ printf "  %s (%s)\n", $2, $3 }' <<<"$left" >&2
  exit 1
fi
echo "  all selections confirmed"

echo "Done. Selection is per Plex account — other household accounts are unchanged."
