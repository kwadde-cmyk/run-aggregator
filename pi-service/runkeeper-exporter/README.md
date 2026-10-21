# Runkeeper Exporter (Raspberry Pi)

Downloads activity exports from runkeeper.com/exportData using a persistent browser session.

## Setup on the Pi

```bash
cd pi-service/runkeeper-exporter
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
playwright install chromium
```

## First login (once)

```bash
python3 export_runkeeper.py --login
```

A browser window opens. Log in with your ASICS/Runkeeper account (email code). Press Enter in the terminal when done. The session is stored in `~/.runkeeper-profile`.

## Download export

```bash
python3 export_runkeeper.py --days 10
```

The ZIP with GPX files is saved to `~/runkeeper-exports/`.

## Notes

- Selectors on the export page may need small adjustments if Runkeeper changes the UI.
- On a Pi 4 the first Playwright install and Chromium download can take a while.
- For headless use after the first login, omit `--login`.
- The Flutter app can later read the GPX files from a shared folder or a simple local HTTP endpoint.
