@echo off
REM Opens the RS3 Chat Bridge window. Needs Python 3 from python.org.
cd /d "%~dp0"
where pyw >nul 2>nul && (start "" pyw bridge\bridge_gui.py) || (start "" pythonw bridge\bridge_gui.py)
