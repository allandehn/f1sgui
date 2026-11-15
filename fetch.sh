#!/bin/bash
# Fetch the active F1 race weekend from OpenF1 and print one JSON object for
# the f1 bar plugin. Mirrors f1schedule's Go logic (internal/schedule,
# internal/cache): ongoing -> upcoming -> (cached: last completed) weekend,
# testing filtered, cancelled filtered, cache fallback when OpenF1 locks
# unauthenticated access during a live session.
#
# stdout: the JSON object (always, on success). stderr: notes. exit 0.
set -u

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/f1schedule"
CACHE="$CACHE_DIR/schedule.json"
BASE="https://api.openf1.org/v1"

year=$(date +%Y)
if [ "$(date +%m)" -ge 11 ]; then year2=$((year + 1)); else year2=""; fi

fetch() { # $1 = endpoint, sets REPLY
	curl -sf --max-time 15 "$BASE/$1" || return 1
}

fetch_year() { # $1 = year; writes M_JSON/S_JSON (first) or M_JSON2/S_JSON2 (second call)
	local m s attempt
	for attempt in 1 2 3; do
		m=$(fetch "meetings?year=$1") && s=$(fetch "sessions?year=$1") && {
			if [ -z "$M_JSON" ]; then
				M_JSON=$m
				S_JSON=$s
			else
				M_JSON2=$m
				S_JSON2=$s
			fi
			return 0
		}
		# 429s and transient failures: wait and retry, like the Go client.
		sleep 1
	done
	return 1
}

M_JSON=""
S_JSON=""
M_JSON2=""
S_JSON2=""

if fetch_year "$year"; then
	if [ -n "$year2" ] && fetch_year "$year2"; then
		M_JSON=$(printf '%s%s' "$M_JSON" "$M_JSON2" | jq -s 'add')
	fi
else
	M_JSON=""
fi

live_locked=0
if [ -z "$M_JSON" ]; then
	# Couldn't fetch. Distinguish OpenF1's live-session lock from other errors:
	# the lock is a 401 with a marker string in the body.
	body=$(curl -s --max-time 15 "$BASE/meetings?year=$year" -w $'\n%{http_code}' || true)
	code=${body##*$'\n'}
	if [ "$code" = "401" ]; then
		live_locked=1
	fi
	M_JSON=""
fi

cached=0
saved_at=""
if [ -n "$M_JSON" ]; then
	# Fresh data: replace this year's entries in the cache, keep other years,
	# atomically (cache.Save semantics).
	mkdir -p "$CACHE_DIR"
	tmp="$CACHE_DIR/.tmp.$$"
	this_year=$(date +%Y)
	next_year=$((this_year + 1))
	if [ -f "$CACHE" ]; then
		jq --argjson m "${M_JSON:-\[\]}" --argjson s "${S_JSON:-\[\]}" --arg m2 "$M_JSON2" --arg s2 "$S_JSON2" \
			--arg ty "$this_year" --arg ny "$next_year" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
			.meetings[$ty] = $m | .sessions[$ty] = $s
			| (if $m2 != "" then .meetings[$ny] = ($m2 | fromjson) else . end)
			| (if $s2 != "" then .sessions[$ny] = ($s2 | fromjson) else . end)
			| .saved_at = $now' "$CACHE" >"$tmp" 2>/dev/null && mv "$tmp" "$CACHE" || { rm -f "$tmp"; echo "cache write failed" >&2; }
	else
		jq -n --argjson m "${M_JSON:-\[\]}" --argjson s "${S_JSON:-\[\]}" --arg m2 "$M_JSON2" --arg s2 "$S_JSON2" \
			--arg ty "$this_year" --arg ny "$next_year" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
			{saved_at: $now,
			 meetings: (if $m2 != "" then {($ty): $m, ($ny): ($m2 | fromjson)} else {($ty): $m} end),
			 sessions: (if $s2 != "" then {($ty): $s, ($ny): ($s2 | fromjson)} else {($ty): $s} end)}' >"$tmp" 2>/dev/null && mv "$tmp" "$CACHE" || { rm -f "$tmp"; echo "cache write failed" >&2; }
	fi
else
	if [ -f "$CACHE" ]; then
		cached=1
		saved_at=$(jq -r '.saved_at' "$CACHE" 2>/dev/null || echo "")
		M_JSON=$(jq -c '[.meetings[][]]' "$CACHE" 2>/dev/null)
		S_JSON=$(jq -c '[.sessions[][]]' "$CACHE" 2>/dev/null)
	else
		echo "no data from OpenF1 and no cache at $CACHE" >&2
		exit 1
	fi
fi

# Pick the active weekend, exactly like weekendFromData. jq does the whole
# pipeline in one pass: build meeting map, join sessions, bucket weekends.
# Debug hook: F1_FAKE_LIVE=1 marks the next session as running now (for UI tests).
OUT=$(jq -n --argjson meetings "${M_JSON:-\[\]}" --argjson sessions "${S_JSON:-\[\]}" \
	--arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson cached "$cached" --arg saved_at "$saved_at" '
  def israce: ([.meeting_name | ascii_downcase] | contains(["testing"]) | not);
  ($now | fromdateiso8601) as $now
  | ($meetings | map(select(.is_cancelled == false and israce)) | map({key: (.meeting_key | tostring), value: .}) | from_entries) as $mmap
  | [$sessions[]
     | select(.is_cancelled == false)
     | select(. as $ses | ($mmap | has(($ses.meeting_key | tostring))))
     | {mk: .meeting_key,
        s: (.date_start | sub("\\+00:00$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime),
        e: (.date_end | sub("\\+00:00$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime),
        ses: .}] | sort_by(.s)
  | group_by(.mk)
  | map({
      key: .[0].mk,
      first: .[0].s,
      last: (map(.e) | max),
      sessions: .,
      ses0: .[0].ses
    })
  | {
      ongoing:  map(select($now >= .first and $now < .last))  | sort_by(.first),
      upcoming: map(select($now < .first))                    | sort_by(.first),
      past:     map(select($now >= .last))                    | sort_by(.last)
    }
  | (if (.ongoing | length) > 0 then {w: .ongoing[0], ongoing: true}
     elif (.upcoming | length) > 0 then {w: .upcoming[0], ongoing: false}
     elif $cached == 1 and (.past | length) > 0 then {w: .past[-1], ongoing: false}
     else empty end) as $pick
    | if $pick == null then empty else
    { meeting:   $mmap[($pick.w.ses0.meeting_key | tostring)].meeting_name,
      location:  $pick.w.ses0.location,
      country:   $pick.w.ses0.country_name,
      circuit:   $pick.w.ses0.circuit_short_name,
      gmt_offset: $pick.w.ses0.gmt_offset,
      ongoing:   $pick.ongoing,
      cached:    ($cached == 1),
      saved_at:  $saved_at,
      sessions: [$pick.w.sessions[] | {name: .ses.session_name, type: .ses.session_type,
                                        start: .s, end: .e}] }
    end')
if [ "${F1_FAKE_LIVE:-0}" = "1" ]; then
  printf '%s' "$OUT" | jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    (.sessions[0].start = ($now | fromdateiso8601) - 300)
    | .sessions[0].end = ((.sessions[0].start) + 7200)'
else
  printf '%s' "$OUT"
fi