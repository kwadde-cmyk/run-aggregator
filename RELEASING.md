# Release auf ZAPstore

Nächster Stand in `pubspec.yaml`: `1.0.5+2005`. Die Zahl nach `+` ist der Android-`versionCode`. Sie muss über **2004** bleiben und bei jedem Release steigen. Auf dem Relay liegen schon versionCode 2001 (1.0.0), 2003 (1.0.3) und 2004 (1.0.4, arm64-Split). Ein kleinerer Code ist kein Update.

`flutter build apk --split-per-abi` nicht verwenden. Flutter setzt den Code dann auf `ABI * 1000 + Buildnummer` (arm64 = 2000 + N). Genau so sind 2001, 2003 und 2004 entstanden. Der Workflow baut ein universelles APK und bricht ab, wenn der `versionCode` nicht die Buildnummer aus der pubspec ist oder nicht über 2004 liegt.

Lokales Signieren und der SHA-1 für Google stehen in `RELEASE.md`.

## Release bauen und veröffentlichen

1. In `pubspec.yaml` die Version anheben, committen und auf `main` mergen.
2. GitHub → Actions → **Release** → Run workflow.
   - Branch: `main`
   - `version`: `v1.0.5` (muss zum Namen in der pubspec passen)
   - `publish_zapstore`: an
3. Der Job `build` baut die APK und legt das GitHub-Release an.
4. Der Job `publish` ruft **Publish to ZAPstore** auf.

Das Release nicht selbst im GitHub-UI anlegen und auf einen zweiten Workflow warten. Releases, die mit `GITHUB_TOKEN` entstehen, starten keine anderen Workflows.

## Nur den ZAPstore-Publish wiederholen

Wenn das GitHub-Release schon existiert (Build grün, Publish rot):

Actions → **Publish to ZAPstore** → Run workflow, Branch `main`, `version` z.B. `v1.0.5`.

Der Lauf lädt `app-release.apk` dieses Tags nach `build/app/outputs/flutter-apk/app-release.apk`, veröffentlicht die `zapstore.yaml` aus dem Repo und prüft CDN plus Relay. Er baut nicht neu und nimmt keine Split-APK. In **Release** lässt sich der Job `publish` auch einzeln erneut starten; das ist derselbe Workflow.

## Was der Publish macht

Gleicher Aufruf wie in `scriptwerk-android`, das mit derselben npub schon auf ZAPstore veröffentlicht:

```bash
timeout 600 zsp publish --quiet --verbose zapstore.yaml
```

`zsp` v0.4.17. Keine weiteren Flags.

- `--quiet` beantwortet Rückfragen. Ein `-y` gibt es in diesem Binary nicht, die zsp-README erwähnt es trotzdem.
- `--verbose` schreibt jede Relay-Zeile ins Log. Kein `--json` und kein `script`-Wrapper. Beides hat die OK/FAILED-Zeilen verschluckt. Lauf 40390136644 war dadurch grün, die APK `d5e06967…` liegt aber mit HTTP 404 auf `cdn.zapstore.dev`, und kind 30063 für 1.0.4 ist nicht auf dem Relay.
- Argument ist die Datei `zapstore.yaml` im Repo, nicht eine APK und nicht eine generierte Kopie. Eine APK als Argument ignoriert die Datei (pubkey, summary). `release_source` zeigt auf `./build/app/outputs/flutter-apk/app-release.apk`. Der exakte Name statt eines Globs: in dem Ordner können auch Debug- oder Split-APKs liegen.
- `repository` ist genau `https://github.com/kwadde-cmyk/run-aggregator`. Das Relay liest diese Datei im öffentlichen Repo und whitelistet die `pubkey`. Die `pubkey` muss die Identität des Signers sein (die Event-npub), nicht der Remote-Signer aus der `bunker://`-URL.
- Die Zeile `pubkey` kam erst mit Commit `071a2ce` (2026-10-26, etwa 21:23 UTC) ins Repo, nach allen fehlgeschlagenen Läufen. Ohne sie konnte das Relay die npub aus dieser Datei nicht whitelisten. Das ist ein wahrscheinlicher Grund, warum die Uploads abgelehnt wurden, obwohl zsp Events geschrieben hat.
- Keine eigenen Relays oder CDN-URLs. zsp nimmt `wss://relay.zapstore.dev` und `https://cdn.zapstore.dev`.
- Ohne `--offline` lädt zsp selbst zu Blossom hoch und schreibt auf das Relay. Ein zweites Python-Publish ist unnötig; Lauf 40391405904 ist nach einer Sekunde an `No module named 'websockets'` gestorben.
- Danach muss HEAD `https://cdn.zapstore.dev/<sha256>` **200** sein (GET über den Redirect 200 oder 206) und kind 30063 plus kind 3063 für diese Version auf dem Relay liegen. Sonst ist der Job rot, auch wenn zsp 0 geliefert hat.
- `--overwrite-release` ist absichtlich nicht dabei. Liegt die Version schon auf dem Relay, macht zsp nichts und `--quiet` druckt dazu keine Warnung (Exit 0). Fehlt die APK dann auf dem CDN, lädt ein erneuter Lauf sie nicht noch einmal hoch. Die Prüfung danach macht den Job rot. Der Schalter bleibt aus dem Workflow draußen.

## Secrets

Namen bleiben:

- `KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`
- `SIGN_WITH` (Bunker-URL `bunker://…`). Im anderen Repo heißt dasselbe Secret `ZAPSTORE_SIGN_WITH`. Hier bleibt der Name `SIGN_WITH`.
- `ZSP_BUNKER_CLIENT_KEY` (64 Hex-Zeichen, derselbe Client-Key wie beim ersten Bunker-Connect, `openssl rand -hex 32`)

Der Publish schreibt den Client-Key in demselben Schritt wie `zsp` nach `$RUNNER_TEMP/cfg/zsp/bunker-keys/<bunker-pubkey>.key` (chmod 600). Der Dateiname ist der Remote-Signer aus der Bunker-URL, nicht die npub. `GITHUB_TOKEN` geht in demselben Schritt mit.

## Wenn der Publish rot bleibt

- `zapstore.yaml` mit `repository` und `pubkey` muss auf dem Branch liegen, den der Workflow auscheckt (`main`).
- `cdn.zapstore.dev` kann den Upload trotzdem ablehnen (Reputation / Whitelist). Die Relay-Whitelist aus `zapstore.yaml` gilt nicht automatisch für das CDN. zsp meldet dann `unauthorized` bzw. `whitelist` und der Job wird rot. Liefert zsp trotzdem 0, fängt die CDN-Prüfung den 404 ab. Die npub `npub1hsrqgwepcd9t3t5q9nm2jjvvz626sk6fjhzyqw3ahfpgrz67034sldsnpz` muss auf dem CDN hochladen dürfen. Danach **Publish to ZAPstore** für denselben Tag erneut starten, ohne die Version anzuheben. Liegt kind 30063 für diese Version schon auf dem Relay und der Blob fehlt, siehe den Hinweis zu `--overwrite-release` oben.
- Zertifikat verknüpfen (`zsp identity --link-key`) ist optional, keine Voraussetzung. `scriptwerk-android` veröffentlicht mit derselben npub, ohne dass der Befehl dort gelaufen wäre. Mit `--quiet` ist ein fehlender Zertifikats-Proof für zsp ein No-Op. Der Workflow übergibt `--skip-certificate-linking` nicht. Wer den Proof trotzdem einmal setzen will, kann das lokal mit dem Release-Keystore machen.
