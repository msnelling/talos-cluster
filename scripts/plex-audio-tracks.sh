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
#        Without --apply it prints the plan and changes nothing.

set -euo pipefail

readonly NAMESPACE="db3000"
readonly SECTION="${PLEX_SECTION:-1}"
readonly EXCLUDE_RE='commentar|descri|descry|isolated|karaoke|sing-?along'

APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=plex \
  -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD" ]; then
  echo "No running Plex pod in $NAMESPACE" >&2
  exit 1
fi

# The token is read from Preferences.xml inside the pod so it never reaches
# this host's process table.
# shellcheck disable=SC2016  # expands in the remote shell, not this one
readonly REMOTE_TOKEN='
  prefs=$(find /config -name Preferences.xml 2>/dev/null | head -1)
  tok=$(sed -n "s/.*PlexOnlineToken=\"\([^\"]*\)\".*/\1/p" "$prefs")
'

fetch_keys() {
  # shellcheck disable=SC2016
  kubectl exec -n "$NAMESPACE" "$POD" -- sh -c "
    $REMOTE_TOKEN
    curl -sSf -H 'Accept: application/json' \
      \"http://localhost:32400/library/sections/\$1/all?X-Plex-Token=\$tok\"
  " _ "$SECTION" | jq -r '.MediaContainer.Metadata[]?.ratingKey'
}

# fetch_detail <<<"$keys"
# The section listing omits stream detail, so each item is fetched separately.
# curl's status is checked per item: piping it straight into tr would discard
# it, and the remote shell is dash, which has neither set -e nor pipefail. A
# swallowed failure here would drop items from the plan with no visible sign.
fetch_detail() {
  # shellcheck disable=SC2016
  kubectl exec -n "$NAMESPACE" -i "$POD" -- sh -c "
    $REMOTE_TOKEN
    failed=0
    while read -r k; do
      [ -n \"\$k\" ] || continue
      if body=\$(curl -sSf -H 'Accept: application/json' \
           \"http://localhost:32400/library/metadata/\$k?X-Plex-Token=\$tok\"); then
        printf '%s' \"\$body\" | tr -d '\n'
        printf '\n'
      else
        echo \"  ratingKey \$k: metadata fetch failed\" >&2
        failed=\$((failed+1))
      fi
    done
    [ \"\$failed\" -eq 0 ]
  "
}

# build_plan <<<"$detail"
# A filter chain, deliberately not a score. The steps below are listed in the
# order the code applies them, though each is an independent predicate so the
# order does not affect the result — only the final sort is order-sensitive.
#   1. candidates are the audio streams that are not currently selected
#   2. drop commentary / audio-description / isolated-score tracks
#   3. drop languages differing from the selected track (keeps Russian dubs out)
#   4. keep only E-AC-3 and AC-3, so DTS, FLAC, PCM, AAC and the rest are never
#      candidates — the chain cannot decode them either
#   5. rank eac3+atmos > eac3 > ac3, then by channel count
#
# Atmos outranks channel count on purpose: a 5.1 E-AC-3 JOC track carries
# height to the Arc Ultra, a 7.1 E-AC-3 track without Atmos does not.
build_plan() {
  jq -rn --arg ex "$EXCLUDE_RE" '
    [ inputs.MediaContainer.Metadata[]?
      | . as $m
      | .Media[]?.Part[]?
      | . as $p
      | [ .Stream[]? | select(.streamType == 2) ] as $auds
      | ( $auds | map(select(.selected == true)) | first ) as $sel
      | select($sel != null and $sel.codec == "truehd")
      | ( $auds
          | map(select(.selected != true))
          | map(select(
              ( (.extendedDisplayTitle // "") + " "
              + (.displayTitle // "") + " "
              + (.title // "") )
              | ascii_downcase | test($ex) | not ))
          | map(select(
              if ($sel.languageCode // "") != "" then
                (.languageCode // "") == $sel.languageCode
              else
                ((.languageCode // "") == "") or ((.languageCode // "") == "eng")
              end ))
          | map(select(.codec == "eac3" or .codec == "ac3"))
          | map(. + { rank:
              ( if .codec == "eac3"
                   and ( ((.extendedDisplayTitle // "") + (.displayTitle // ""))
                         | ascii_downcase | test("atmos") ) then 3
                elif .codec == "eac3" then 2
                else 1 end ) })
          | sort_by(.rank, (.channels // 0))
          | reverse ) as $cands
      | { title: $m.title, partId: $p.id, cand: ($cands | first) } ]
    | sort_by(.title)
    | .[]
    | if .cand == null then
        [ "SKIP", .title, "-", "no usable E-AC-3/AC-3 track" ] | @tsv
      elif .cand.rank == 3 then
        [ "ATMOS", .title, "\(.partId):\(.cand.id)",
          (.cand.extendedDisplayTitle // .cand.displayTitle // .cand.codec) ] | @tsv
      else
        [ "MOVE", .title, "\(.partId):\(.cand.id)",
          (.cand.extendedDisplayTitle // .cand.displayTitle // .cand.codec) ] | @tsv
      end
  '
}

echo "Plex pod: $POD"
echo "Fetching library section ${SECTION}..."
keys=$(fetch_keys)
if [ -z "$keys" ]; then
  echo "Section $SECTION returned no items" >&2
  exit 1
fi
n_keys=$(wc -l <<<"$keys" | tr -d ' ')
echo "  $n_keys items"

echo "Reading audio streams..."
detail=$(fetch_detail <<<"$keys")

# Planning on a short read would look identical to "nothing needs changing".
n_docs=$(jq -n '[inputs] | length' <<<"$detail")
if [ "$n_docs" -ne "$n_keys" ]; then
  echo "Read $n_docs of $n_keys items — refusing to plan on partial data" >&2
  exit 1
fi

plan=$(build_plan <<<"$detail")
atmos=$(awk -F'\t' '$1 == "ATMOS"' <<<"$plan" | wc -l | tr -d ' ')
moves=$(awk -F'\t' '$1 == "MOVE"' <<<"$plan" | wc -l | tr -d ' ')
skips=$(awk -F'\t' '$1 == "SKIP"' <<<"$plan" | wc -l | tr -d ' ')

echo
# awk, not read: IFS=$'\t' treats tab as whitespace and collapses the empty
# fields on SKIP rows, shifting every column after them.
awk -F'\t' 'BEGIN { printf "%-6s %-46s %s\n", "ACTION", "TITLE", "NEW TRACK" }
  NF { printf "%-6s %-46s %s\n", $1, substr($2, 1, 46), $4 }' <<<"$plan"
echo
echo "Inspected $n_docs items; $((atmos + moves + skips)) have TrueHD selected."
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
# shellcheck disable=SC2016
awk -F'\t' '$1 == "MOVE" || $1 == "ATMOS" { print $3 }' <<<"$plan" \
  | kubectl exec -n "$NAMESPACE" -i "$POD" -- sh -c "
      $REMOTE_TOKEN
      ok=0; failed=0
      while IFS=: read -r part stream; do
        [ -n \"\$part\" ] || continue
        code=\$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
          \"http://localhost:32400/library/parts/\$part?audioStreamID=\$stream&X-Plex-Token=\$tok\")
        case \"\$code\" in
          2*) ok=\$((ok+1)) ;;
          *)  echo \"  part \$part -> stream \$stream failed (http \$code)\" >&2
              failed=\$((failed+1)) ;;
        esac
      done
      echo \"  \$ok applied, \$failed failed\"
      [ \"\$failed\" -eq 0 ]
    "

# A 2xx does not prove the selection moved, so re-read and rebuild the plan.
# Anything still pending means Plex accepted a PUT without acting on it.
echo "Verifying..."
recheck=$(build_plan <<<"$(fetch_detail <<<"$keys")")
left=$(awk -F'\t' '$1 == "MOVE" || $1 == "ATMOS"' <<<"$recheck" | wc -l | tr -d ' ')
if [ "$left" -ne 0 ]; then
  echo "$left selection(s) did not take:" >&2
  awk -F'\t' '$1 == "MOVE" || $1 == "ATMOS" { printf "  %s (%s)\n", $2, $3 }' <<<"$recheck" >&2
  exit 1
fi
echo "  all selections confirmed"

echo "Done. Selection is per Plex account — other household accounts are unchanged."
