#!/bin/bash
# Opens the RS3 Chat Bridge window on Linux.
cd "$(dirname "$0")"
if ! python3 -c "import tkinter" 2>/dev/null; then
  echo "Tkinter is missing. On Ubuntu/Debian run:  sudo apt install python3-tk"
  exit 1
fi
exec python3 bridge/bridge_gui.py
