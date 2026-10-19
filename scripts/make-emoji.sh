#!/bin/sh
# Regenerates Resources/emoji.tsv (emoji, name, keywords) from emojibase-data (MIT).
# Run it when a new Unicode emoji version ships: sh scripts/make-emoji.sh 16
set -e
v=${1:-16}
curl -sfL "https://cdn.jsdelivr.net/npm/emojibase-data@$v/en/compact.json" |
  jq -r '[.[] | select(.group != null and .group != 2)] | sort_by(.order) | .[] |
         [.unicode, .label, ((.tags // []) + (.emoticon // [] | if type == "string" then [.] else . end) | join(" "))] | @tsv' \
  > Resources/emoji.tsv
wc -l Resources/emoji.tsv
