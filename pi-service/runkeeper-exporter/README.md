# Runkeeper Exporter (Raspberry Pi, headless)

Downloads activity exports from runkeeper.com/exportData using a persistent browser session.

## Setup

```bash
cd pi-service/runkeeper-exporter
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
playwright install chromium
```

## Login (Pi has no GUI)

You need a valid browser profile once.

**Option A – Login on a desktop, then copy the profile**
1. On a machine with a display run the script once with a headed browser (or just log in manually and export cookies).
2. Copy the folder `~/.runkeeper-profile` to the Pi (same path).

**Option B – Use xvfb on the Pi**
```bash
sudo apt install -y xvfb
xvfb-run python3 export_runkeeper.py --login
```
(A virtual display is created; complete the login if a window appears, or use a VNC viewer.)

## Download export

```bash
python3 export_runkeeper.py --days 10
```

ZIP is saved to `~/runkeeper-exports/`.

## Notes

- Selectors on the export page may need small adjustments if Runkeeper changes the UI.
- On a Pi 4 the first Chromium download can take a while.
- After the first successful login the profile can be reused headlessly.
