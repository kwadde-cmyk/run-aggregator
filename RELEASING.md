# Release auf ZAPstore

Nächster Stand in `pubspec.yaml`: `1.0.7+2007`. Die Zahl nach `+` ist der Android-`versionCode`. Sie muss über **2004** bleiben und bei jedem Release steigen. Auf dem Relay liegen schon versionCode 2001 (1.0.0), 2003 (1.0.3) und 2004 (1.0.4, arm64-Split). Ein kleinerer Code ist kein Update.

`flutter build apk --split-per-abi` nicht verwenden. Flutter setzt den Code dann auf `ABI * 1000 + Buildnummer` (arm64 = 2000 + N). Genau so sind 2001, 2003 und 2004 entstanden. Der Workflow baut ein universelles APK und bricht ab, wenn der `versionCode` nicht die Buildnummer aus der pubspec ist oder nicht über 2004 liegt.

Lokales Signieren und der SHA-1 für Google stehen in `RELEASE.md`.

## Release bauen und veröffentlichen

1. In `pubspec.yaml` die Version anheben, committen und auf `main` mergen.
2. GitHub → Actions → **Release** → Run workflow.
   - Branch: `main`
   - `version`: `v1.0.7` (muss zum Namen in der pubspec passen)
   - `publish_zapstore`: an
3. Der Job `build` baut die APK und legt das GitHub-Release an.
4. Der Job `publish` ruft **Publish to ZAPstore** auf.

Das Release nicht selbst im GitHub-UI anlegen und auf einen zweiten Workflow warten. Releases, die mit `GITHUB_TOKEN` entstehen, starten keine anderen Workflows.

## Nur den ZAPstore-Publish wiederholen

Wenn das GitHub-Release schon existiert (Build grün, Publish rot):

Actions → **Publish to ZAPstore** → Run workflow, Branch `main`, `version` z.B. `v1.0.7`.

Der Lauf lädt `app-release.apk` dieses Tags nach `build/app/outputs/flutter-apk/app-release.apk`, veröffentlicht die `zapstore.yaml` aus dem Repo und prüft CDN plus Relay. Er baut nicht neu und nimmt keine Split-APK. In **Release** lässt sich der Job `publish` auch einzeln erneut starten; das ist derselbe Workflow.

## Was der Publish macht

Gleicher Aufruf wie in `scriptwerk-android`, das mit derselben npub schon auf ZAPstore veröffentlicht:

```bash
timeout 600 zsp publish --quiet --verbose zapstore.yaml
```

`zsp` v0.4.17. Keine weiteren Flags.

- `--quiet` beantwortet Rückfragen und legt **keinen** Zertifikats-Proof an. `checkAndLinkCertificate` kehrt dann ohne Warnung zurück. Ein `-y` gibt es in diesem Binary nicht, die zsp-README erwähnt es trotzdem. Der Proof muss vorher auf dem Relay liegen, sonst bricht der Workflow vor `zsp publish` ab. Siehe unten.
- `--verbose` schreibt jede Relay-Zeile ins Log. Kein `--json` und kein `script`-Wrapper. Beides hat die OK/FAILED-Zeilen verschluckt. Lauf 40390136644 war dadurch grün, die APK `d5e06967…` liegt aber mit HTTP 404 auf `cdn.zapstore.dev`, und kind 30063 für 1.0.4 ist nicht auf dem Relay.
- Argument ist die Datei `zapstore.yaml` im Repo, nicht eine APK und nicht eine generierte Kopie. Eine APK als Argument ignoriert die Datei (pubkey, summary). `release_source` zeigt auf `./build/app/outputs/flutter-apk/app-release.apk`. Der exakte Name statt eines Globs: in dem Ordner können auch Debug- oder Split-APKs liegen.
- `repository` ist genau `https://github.com/kwadde-cmyk/run-aggregator`. Das Relay liest diese Datei im öffentlichen Repo und whitelistet die `pubkey`. Die `pubkey` muss die Identität des Signers sein (die Event-npub), nicht der Remote-Signer aus der `bunker://`-URL.
- Die Zeile `pubkey` kam erst mit Commit `071a2ce` (2026-10-26, etwa 21:23 UTC) ins Repo, nach allen fehlgeschlagenen Läufen. Ohne sie konnte das Relay die npub aus dieser Datei nicht whitelisten. Das ist ein wahrscheinlicher Grund, warum die Uploads abgelehnt wurden, obwohl zsp Events geschrieben hat.
- Keine eigenen Relays oder CDN-URLs. zsp nimmt `wss://relay.zapstore.dev` und `https://cdn.zapstore.dev`.
- Ohne `--offline` lädt zsp selbst zu Blossom hoch und schreibt auf das Relay. Ein zweites Python-Publish ist unnötig; Lauf 40391405904 ist nach einer Sekunde an `No module named 'websockets'` gestorben.
- Danach muss HEAD `https://cdn.zapstore.dev/<sha256>` **200** sein (GET über den Redirect 200 oder 206) und kind 30063 plus kind 3063 für diese Version auf dem Relay liegen. Sonst ist der Job rot, auch wenn zsp 0 geliefert hat.
- `--overwrite-release` ist absichtlich nicht dabei. Liegt die Version schon auf dem Relay, macht zsp nichts und `--quiet` druckt dazu keine Warnung (Exit 0). Fehlt die APK dann auf dem CDN, lädt ein erneuter Lauf sie nicht noch einmal hoch. Die Prüfung danach macht den Job rot. Der Schalter bleibt aus dem Workflow draußen.

## Zertifikat verknüpfen (Pflicht, einmalig)

Das ist keine Option. Die frühere Fassung dieser Datei hat das falsch beschrieben.

`zsp publish --quiet` legt kind 30509 nicht an und bricht nicht ab, wenn er fehlt. Relay v2 schaltet einen Eintrag erst frei, wenn ein **aktiver** kind 30509 das APK-Signaturzertifikat mit der Publisher-npub verknüpft. Sonst bleiben App-, Release- und Asset-Events pending: `cdn.zapstore.dev` antwortet 404 `blob not found`, und kind 30063/3063 sind nicht abfragbar. Pending-Einträge verfallen nach etwa 5 Stunden.

Genau das war Lauf [40412044876](https://github.com/kwadde-cmyk/run-aggregator/actions/runs/40412044876) (Release v1.0.5): zsp meldete Relay OK, der Upload wurde angenommen, der Blob `cef92634…` blieb 404. Es gibt keinen kind 30509, der das Zertifikat `835c21049f799d681d734780190ddf29c3abfe81e981fd9b0c52a4f0b88bb474` mit `bc06043b21c34ab8ae802cf6a9498c1695a85b4995c4403a3dba42818b5e7c6b` verbindet. Der Fingerprint steht im APK als `cert_fingerprint` (`zsp utils extract-apk`).

Einmal lokal anlegen, mit dem Keystore, der die Release-APK signiert (`RELEASE.md`: `~/run-aggregator.keystore`, Alias `runaggregator`, derselbe Alias wie das Secret `KEY_ALIAS`). Gültig 1 Jahr (`--link-key-expiry` ist standardmäßig `1y`), danach jährlich erneuern, sonst ist der Proof abgelaufen und der Workflow wird wieder rot. Amber muss laufen, `SIGN_WITH` ist dieselbe Bunker-URL wie das Secret `SIGN_WITH`. `KEYSTORE_PASSWORD` ist das Store-Passwort (`STORE_PASSWORD`), `KEYSTORE_KEY_PASSWORD` das Key-Passwort (`KEY_PASSWORD`).

```bash
KEYSTORE_PASSWORD='…' \
KEYSTORE_KEY_PASSWORD='…' \
SIGN_WITH='bunker://…' \
  zsp identity --link-key ~/run-aggregator.keystore \
  --key-alias runaggregator \
  --relays wss://relay.zapstore.dev
```

Prüfen, am besten mit der gebauten `app-release.apk` (der Befehl fragt nach der npub `npub1hsrqgwepcd9t3t5q9nm2jjvvz626sk6fjhzyqw3ahfpgrz67034sldsnpz` und muss `ACTIVE` zeigen):

```bash
zsp identity --verify app-release.apk --relays wss://relay.zapstore.dev
```

Oder auf `wss://relay.zapstore.dev`: kind **30509**, `authors` = `bc06043b21c34ab8ae802cf6a9498c1695a85b4995c4403a3dba42818b5e7c6b`, `#d` = `835c21049f799d681d734780190ddf29c3abfe81e981fd9b0c52a4f0b88bb474`, Tag `expiry` in der Zukunft, nicht `revoked`. Dieselbe Abfrage macht **Publish to ZAPstore** vor `zsp publish` und bricht mit `::error::` ab, wenn der Proof fehlt oder abgelaufen ist.

Danach nicht **Release** neu starten. Das GitHub-Release `v1.0.5` gibt es schon. Actions → **Publish to ZAPstore**, `version` `v1.0.5`.

## Secrets

Namen bleiben:

- `KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`
- `SIGN_WITH` (Bunker-URL `bunker://…`). Im anderen Repo heißt dasselbe Secret `ZAPSTORE_SIGN_WITH`. Hier bleibt der Name `SIGN_WITH`.
- `ZSP_BUNKER_CLIENT_KEY` (64 Hex-Zeichen, derselbe Client-Key wie beim ersten Bunker-Connect, `openssl rand -hex 32`)

Der Publish schreibt den Client-Key in demselben Schritt wie `zsp` nach `$RUNNER_TEMP/cfg/zsp/bunker-keys/<bunker-pubkey>.key` (chmod 600). Der Dateiname ist der Remote-Signer aus der Bunker-URL, nicht die npub. `GITHUB_TOKEN` geht in demselben Schritt mit.

## Wenn der Publish rot bleibt

- `zapstore.yaml` mit `repository` und `pubkey` muss auf dem Branch liegen, den der Workflow auscheckt (`main`).
- Fehlt der kind 30509 oder ist er abgelaufen, ist der Job rot, **bevor** zsp veröffentlicht. Befehl und Prüfung stehen im Abschnitt oben. Ein 404 nach einem grünen zsp-Lauf ist dasselbe Bild wie bei v1.0.5: Upload angenommen, Eintrag bleibt pending, CDN `blob not found`. Die Prüfung danach wartet länger (8 Versuche, 15 Sekunden Abstand) und schreibt diese Ursache ins Log. 401/403 ist etwas anderes: die npub darf nicht auf `cdn.zapstore.dev` hochladen. Die Relay-Whitelist aus `zapstore.yaml` gilt nicht für das CDN.
- `--overwrite-release` bleibt aus dem Workflow draußen. Liegt die Version schon als abfragbares kind 30063 auf dem Relay und der Blob fehlt, lädt ein erneuter Lauf sie nicht noch einmal hoch. Pending-Events, die ohne Proof nie abfragbar waren, sind nach etwa 5 Stunden weg.
