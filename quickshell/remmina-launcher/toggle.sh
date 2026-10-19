#!/usr/bin/env bash
if qs -c remmina-launcher kill 2>/dev/null; then exit 0; fi
exec qs -c remmina-launcher
