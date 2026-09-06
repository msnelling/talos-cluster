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
echo "Plex pod: $POD"

# The token is read from Preferences.xml inside the pod so it never reaches
# this host's process table.
# shellcheck disable=SC2016  # $1/$tok are for the remote shell, not this one
readonly REMOTE_TOKEN='
  prefs=$(find /config -name Preferences.xml 2>/dev/null | head -1)
  tok=$(sed -n "s/.*PlexOnlineToken=\"\([^\"]*\)\".*/\1/p" "$prefs")
'

echo "Fetching library section ${SECTION}..."
# shellcheck disable=SC2016
keys=$(kubectl exec -n "$NAMESPACE" "$POD" -- sh -c "
  $REMOTE_TOKEN
  curl -sf -H 'Accept: application/json' \
    \"http://localhost:32400/library/sections/\$1/all?X-Plex-Token=\$tok\"
" _ "$SECTION" | jq -r '.MediaContainer.Metadata[]?.ratingKey')

if [ -z "$keys" ]; then
  echo "Section $SECTION returned no items" >&2
  exit 1
fi
echo "  $(wc -l <<<"$keys" | tr -d ' ') items"

# The section listing omits stream detail, so each item is fetched individually.
echo "Reading audio streams..."
# shellcheck disable=SC2016
detail=$(kubectl exec -n "$NAMESPACE" -i "$POD" -- sh -c "
  $REMOTE_TOKEN
  while read -r k; do
    [ -n \"\$k\" ] || continue
    curl -sf -H 'Accept: application/json' \
      \"http://localhost:32400/library/metadata/\$k?X-Plex-Token=\$tok\" | tr -d '\n'
    echo
  done
" <<<"$keys")

# Build the plan as a filter chain, deliberately not a score:
#   1. candidates are the audio streams that are not currently selected
#   2. drop languages differing from the selected track (keeps Russian dubs out)
#   3. drop commentary / audio-description / isolated-score tracks
#   4. rank eac3+atmos > eac3 > ac3, then by channel count
#   5. DTS is never a candidate — the chain cannot decode it either
#
# Atmos outranks channel count on purpose: a 5.1 E-AC-3 JOC track carries
# height to the Arc Ultra, an 7.1 E-AC-3 track without Atmos does not.
plan=$(jq -rn --arg ex "$EXCLUDE_RE" '
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
      [ "SKIP", .title, "", "no usable EAC3/AC3 track" ] | @tsv
    elif .cand.rank == 3 then
      [ "ATMOS", .title, "\(.partId):\(.cand.id)",
        (.cand.extendedDisplayTitle // .cand.displayTitle // .cand.codec) ] | @tsv
    else
      [ "MOVE", .title, "\(.partId):\(.cand.id)",
        (.cand.extendedDisplayTitle // .cand.displayTitle // .cand.codec) ] | @tsv
    end
' <<<"$detail")

atmos=$(awk -F'\t' '$1 == "ATMOS"' <<<"$plan" | wc -l | tr -d ' ')
moves=$(awk -F'\t' '$1 == "MOVE"' <<<"$plan" | wc -l | tr -d ' ')
skips=$(awk -F'\t' '$1 == "SKIP"' <<<"$plan" | wc -l | tr -d ' ')

echo
printf '%-6s %-46s %s\n' "ACTION" "TITLE" "NEW TRACK"
printf '%.0s-' {1..112}; echo
while IFS=$'\t' read -r action title _ids newtrack; do
  [ -n "$action" ] || continue
  printf '%-6s %-46s %s\n' "$action" "${title:0:46}" "$newtrack"
done <<<"$plan"
echo
echo "ATMOS $atmos  — gains height on the Arc Ultra (E-AC-3 JOC)"
echo "MOVE  $moves  — no height either way, but direct plays instead of transcoding"
echo "SKIP  $skips  — no playable alternative track, left on TrueHD"

if [ "$APPLY" != true ]; then
  echo
  echo "Dry run — nothing changed. Re-run with --apply to commit."
  exit 0
fi

echo
echo "Applying..."
# shellcheck disable=SC2016
awk -F'\t' '$1 == "MOVE" || $1 == "ATMOS" { print $3 }' <<<"$plan" \
  | kubectl exec -n "$NAMESPACE" -i "$POD" -- sh -c "
      $REMOTE_TOKEN
      ok=0; fail=0
      while IFS=: read -r part stream; do
        [ -n \"\$part\" ] || continue
        code=\$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
          \"http://localhost:32400/library/parts/\$part?audioStreamID=\$stream&allParts=1&X-Plex-Token=\$tok\")
        case \"\$code\" in
          2*) ok=\$((ok+1)) ;;
          *)  echo \"  part \$part -> stream \$stream failed (http \$code)\" >&2
              fail=\$((fail+1)) ;;
        esac
      done
      echo \"  \$ok applied, \$fail failed\"
      [ \"\$fail\" -eq 0 ]
    "

echo "Done. Selection is per Plex account — other household accounts are unchanged."
