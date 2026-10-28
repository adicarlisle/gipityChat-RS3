"""Builds a standalone RS3 Chat Bridge app for the OS you run it on.

    pip install pyinstaller
    python build.py

Output: dist/RS3ChatBridge.exe (Windows), dist/RS3ChatBridge.app (macOS),
dist/RS3ChatBridge (Linux). The plugin files are bundled inside so the app's
"Install plugin into RS3" button works.
"""
import os

import PyInstaller.__main__

here = os.path.dirname(os.path.abspath(__file__))
plugin = os.path.join(here, "plugin", "twitch-claude-chat")
PyInstaller.__main__.run([
    os.path.join(here, "bridge", "bridge_gui.py"),
    "--name", "RS3ChatBridge",
    "--onefile",
    "--windowed",  # no terminal window
    "--noconfirm",
    "--paths", os.path.join(here, "bridge"),
    "--add-data", f"{plugin}{os.pathsep}plugin/twitch-claude-chat",
    "--distpath", os.path.join(here, "dist"),
    "--workpath", os.path.join(here, "build"),
    "--specpath", os.path.join(here, "build"),
])
