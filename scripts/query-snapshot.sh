#!/bin/bash
# Prints the result rows (ids, and titles where they are stable) for a fixed list of
# queries, using the release build. Run it before and after a change to the search or
# command code and diff the two outputs: `scripts/query-snapshot.sh > before.txt`.
# It only reads. It skips commands that prompt or take long (bt, boot).
set -u
L="$(cd "$(dirname "$0")/.." && pwd)/.build/release/Launcher"
# Rows whose titles change from run to run (random text, live numbers, the network):
# only their ids are compared.
IDS_ONLY="^(lorem|stats|weather|tidy|cb|zalgo|e |cal$|caff|timer$|markup|audio|help|\?)"
queries=(
  "chr" "safari" "hidden files" "wifi" "awake" "kea settings" "12*4" "10 mi in km" "downloads" "markup" "zzzqqqxx"
  "def apple" "ety apple" "cb" "lorem" "lorem 3" "lorem 3 md" "cal" "cal lunch tomorrow 1pm"
  "stats" "help" "help cal" "?" "finder"
  "default md" "default browser" "audio" "weather" "2048" "tidy" "clean" "clean 30s"
  "zones" "caff" "caff 2h" "caff lid" "timer" "timer 5m" "settings" "settings blue"
  "g hello" "c hi" "gpt hi" "p" "e party" "zalgo hi" "ie"
)
for q in "${queries[@]}"; do
  out=$(KEA_QUERY_WAIT="${KEA_QUERY_WAIT:-2}" "$L" --query "$q" 2>/dev/null | grep -E '^[0-9]+\. ')
  if [[ "$q" =~ $IDS_ONLY ]]; then
    rows=$(echo "$out" | sed -E 's/.*\[([^]]*)\].*/\1/' | sed -E 's/^(lorem|timer|cb|clip|zalgo|emoji|audio|weather:day|help)[:.].*/\1:*/' | sort -u | tr '\n' ' ')
  else
    rows=$(echo "$out" | sed -E 's/^[0-9]+\. (.*)  \[([^]]*)\].*/\2 = \1/' | tr '\n' '|')
  fi
  echo "[$q] $rows"
done
