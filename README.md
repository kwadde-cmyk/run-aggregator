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

### Android

1. Clone the repo
2. Set up Flutter SDK
3. `flutter pub get`
4. `flutter run`

For release APK: see GitHub Actions or local `flutter build apk --release` (requires signing setup).

### Web / Self-host

`flutter build web` then serve the `build/web` directory, or use the provided Dockerfile.

### Data Sources

- **Google Health / Fitbit**: Export via Google Takeout or Google Health app (TCX for GPS activities). API migration ongoing (Fitbit API ends ~Oct 2026).
- **ASICS Runkeeper**: Export activities as GPX/TCX from the website or app. Official API available for registered apps.

Raw trackpoints enable split calculations and intermediate times.

## ZAPstore Publishing

Automated via GitHub Actions on release tags. Requires:
- Android signing keystore (as GitHub secrets)
- Nostr signing for ZAPstore (`SIGN_WITH` secret, e.g. bunker URL or nsec)

See `.github/workflows/release.yml` and `zapstore.yaml`.

## Development Status

Initial skeleton. Core data models, import parsers, UI for graphs/tables, and weather fetch to be implemented.

Contributions welcome!
