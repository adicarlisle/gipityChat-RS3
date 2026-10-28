#!/bin/bash
# Double-click to open the RS3 Chat Bridge window. Needs Python 3 from python.org
# (Apple's built-in python3 has an old, buggy Tk).
cd "$(dirname "$0")"
exec python3 bridge/bridge_gui.py
