#!/bin/bash
# An example script command. Copy it to
# ~/.config/omarchy/launcher/commands/ and make it your own.
#
# @launcher.schemaVersion 1
# @launcher.title IP addresses
# @launcher.mode fullOutput
# @launcher.icon 󰩟
# @launcher.packageName Network
# @launcher.description This machine's addresses, per interface

ip -brief address | grep -v '^lo ' | awk '{ printf "%-16s %-8s %s\n", $1, $2, $3 }'
echo
echo "Default route: $(ip route show default | awk '{print $3 " via " $5; exit}')"
