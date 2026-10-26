# Run Aggregator

Aggregate and analyze running data from Google Health (formerly Fitbit) and ASICS Runkeeper.

## Features

- Import raw activity data (GPX, TCX, JSON exports, etc.)
- Analyze distance, heart rate, speed, pace
- Intermediate times / splits for segments
- Filters: weekday, distance, avg HR, total time, pace/km for comparisons
- Weather data integration (outdoor temperature, etc.) via Open-Meteo historical API
- Graphical and tabular views
- Android app (APK for ZAPstore)
- Self-hostable website (Flutter Web + Docker)

## Tech Stack

- Flutter (Android + Web)
- Local storage (SQLite / Hive planned)
- Open-Meteo for weather (no API key needed for non-commercial)
- GitHub Actions for signed APK builds and ZAPstore publishing (see RELEASING.md)

## Getting Started

### Initial Setup

After cloning, generate the full Flutter platform files:

```bash
flutter create --platforms=android,web --org de.kwadde .
flutter pub get
```

Then configure Android signing for release builds (see Flutter docs for keystore).

### Android

1. Clone the repo
2. Set up Flutter SDK
3. Run the create command above if platform folders are missing
4. `flutter pub get`
5. `flutter run`

For release APK: see GitHub Actions or local `flutter build apk --release` (requires signing setup).

### Web / Self-host

`flutter build web` then serve the `build/web` directory, or use the provided Dockerfile / docker-compose.

```bash
docker compose up --build
```

#### Raspberry Pi 4 (4GB) Hosting

**Do not build Flutter on the Pi** – it is too resource-heavy. Build on your desktop instead.

1. On your desktop (after Flutter is set up):
   ```bash
   flutter build web --release
   ```

2. Copy the contents of `build/web/` to a folder `web/` on the Raspberry Pi (e.g. via `scp` or `rsync`).

3. On the Pi, in the directory that contains `web/` and the repo files:
   ```bash
   docker compose -f docker-compose.pi.yml up -d
   ```

The site will be available at `http://<pi-ip>:8080`.

Uses the lightweight `nginx:alpine` image + `nginx.conf` for proper SPA routing.

### Data Sources

- **Google Health / Fitbit**: Export via Google Takeout or Google Health app (TCX for GPS activities). API migration ongoing (Fitbit API ends ~Oct 2026). Prefer file imports for personal use.
- **ASICS Runkeeper**: Export activities as GPX/TCX from the website or app. Official API available for registered apps.

Raw trackpoints enable split calculations and intermediate times.

## ZAPstore Publishing

Releases are started by hand from GitHub Actions. See `RELEASING.md`.

- **Release** builds the signed universal APK, creates the GitHub Release, then publishes to ZAPstore.
- **Publish to ZAPstore** repeats only the publish for an existing tag.

Creating a GitHub Release in the UI does not start those workflows. Signing secrets: `KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`. Nostr signing: `SIGN_WITH` (bunker URL) and `ZSP_BUNKER_CLIENT_KEY`.

## Development Status

Initial skeleton with models, basic UI, Docker, and CI. Core import parsers, split calculations, filters, charts, tables, and weather integration to be implemented.

Contributions welcome!
