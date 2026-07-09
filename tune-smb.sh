#!/bin/bash
# tune-smb.sh — make macOS's SMB client behave better with simple NAS boxes
# (Roon ROCK, small NAS units, anything that negotiates an old SMB dialect).
#
# What it does, and nothing else:
#   1. Backs up any existing /etc/nsmb.conf to /etc/nsmb.conf.backup
#   2. Writes /etc/nsmb.conf with three settings:
#        signing_required=no    — never require packet signing (pointless
#                                 overhead on a guest share on your own network)
#        mc_on=no               — turn off SMB "multichannel" (parallel
#                                 connections), which simple servers mishandle
#        notify_off=yes         — stop asking the server to push change
#                                 notifications (chatter simple servers
#                                 handle badly)
#        dir_cache_off=yes      — don't cache directory listings (Apple's own
#                                 documented fix for stale/corrupt listings
#                                 against third-party servers, support
#                                 article 101918)
#
# Deliberately NOT set: max_resp_timeout. Raising it sounds resilient but
# means every hung request blocks whatever asked for it (Finder included)
# for that long. The 30-second default is right.
#
# The change applies the NEXT time a share is mounted: eject the share in
# Finder, then reconnect — ideally by IP (Finder > Go > Connect to Server >
# smb://192.168.x.x/ShareName).
#
# To undo everything:  sudo rm /etc/nsmb.conf   (or restore the .backup)

set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "This needs to change a system file, so run it with sudo:"
  echo "  sudo bash $0"
  exit 1
fi

if [ -f /etc/nsmb.conf ]; then
  cp /etc/nsmb.conf /etc/nsmb.conf.backup
  echo "Existing /etc/nsmb.conf backed up to /etc/nsmb.conf.backup"
fi

printf '[default]\nsigning_required=no\nmc_on=no\nnotify_off=yes\ndir_cache_off=yes\n' > /etc/nsmb.conf

echo "Written /etc/nsmb.conf:"
echo "------------------------"
cat /etc/nsmb.conf
echo "------------------------"
echo "Now eject the share in Finder and reconnect (by IP if you can)."
echo "Check it worked with:  smbutil statshares -a"
