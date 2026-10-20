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
- GitHub Actions for automated APK builds and ZAPstore publishing

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

### Data Sources

- **Google Health / Fitbit**: Export via Google Takeout or Google Health app (TCX for GPS activities). API migration ongoing (Fitbit API ends ~Oct 2026). Prefer file imports for personal use.
- **ASICS Runkeeper**: Export activities as GPX/TCX from the website or app. Official API available for registered apps.

Raw trackpoints enable split calculations and intermediate times.

## ZAPstore Publishing

Automated via GitHub Actions on release tags (or workflow_dispatch). Requires:

- Android signing keystore secrets: `KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`
- Nostr signing for ZAPstore: `SIGN_WITH` secret (bunker URL recommended, or nsec)

See `.github/workflows/release.yml` and `zapstore.yaml`.

To publish: create a GitHub Release with a tag (e.g. v1.0.0). The workflow builds the APK(s) and publishes to ZAPstore (if secrets are set).

## Development Status

Initial skeleton with models, basic UI, Docker, and CI. Core import parsers, split calculations, filters, charts, tables, and weather integration to be implemented.

Contributions welcome!
