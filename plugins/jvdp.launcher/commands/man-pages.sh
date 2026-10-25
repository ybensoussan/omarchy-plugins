#!/bin/bash
# An example list script: a search source of its own, behind the prefix "man".
# It gets the query as $1 and prints one JSON object per line.
#
# @launcher.schemaVersion 1
# @launcher.title Manual pages
# @launcher.mode list
# @launcher.prefix man
# @launcher.icon 󰋗
# @launcher.description Type “man ” and a command to read its manual page

query=${1:-}
[[ -n $query ]] || { echo '{"title": "Type a command name", "icon": "󰋗"}'; exit 0; }

# Names starting with the query first, then any page that mentions it.
{ whatis -l -w "$query*"; apropos -l -- "$query"; } 2>/dev/null | awk '!seen[$1 $2]++' | head -40 | while read -r name section rest; do
  section=${section//[()]/}
  desc=${rest#- }
  jq -cn --arg t "$name($section)" --arg s "$desc" --arg n "$name" --arg sec "$section" \
    '{title: $t, subtitle: $s, icon: "󰋗", action: {run: ["xdg-terminal-exec", "man", $sec, $n]}}'
done
