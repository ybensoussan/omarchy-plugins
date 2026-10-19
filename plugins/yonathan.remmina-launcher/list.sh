#!/usr/bin/env bash
# Output: name<TAB>protocol<TAB>server<TAB>file
for f in "$HOME"/.local/share/remmina/*.remmina; do
  [ -e "$f" ] || continue
  awk -F= -v f="$f" '
    $1=="name"{n=substr($0,6)} $1=="protocol"{p=$2} $1=="server"{s=substr($0,8)}
    END{ if(n=="") {n=f; sub(".*/","",n); sub(".remmina$","",n)} printf "%s\t%s\t%s\t%s\n", n,p,s,f }' "$f"
done | sort -f
