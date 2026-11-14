#!/bin/bash
# Edit Intent Mode's settings — double-click this file.
# Opens a copy of the settings in TextEdit. When you save and press Enter here, the change is handed to
# Intent Mode: tightening applies at once; during lock-down, loosening waits 24 hours (cancel on the lock screen).
clear
echo
echo "  Edit Intent Mode settings"
echo "  ─────────────────────────"
echo
/usr/local/bin/intentmode config edit
echo
read -r -p "Press Enter to close this window." _
