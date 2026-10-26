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

Der Lauf lädt die APK dieses Tags, veröffentlicht sie und prüft CDN plus Relay. Er baut nicht neu. In **Release** lässt sich der Job `publish` auch einzeln erneut starten; das ist derselbe Workflow.

## Was der Publish macht

`zsp` v0.4.17, ungefähr:

```bash
zsp publish --quiet --verbose --overwrite-release \
  --skip-certificate-linking --skip-preview /tmp/zapstore.publish.yaml
```

- `--quiet` beantwortet Rückfragen. Ein `-y` gibt es in diesem Binary nicht, die zsp-README erwähnt es trotzdem.
- Kein `--json` und kein `script`-Wrapper. Beides hat die OK/FAILED-Zeilen pro Event verschluckt. Lauf 40390136644 war dadurch grün, die APK `d5e06967…` liegt aber mit HTTP 404 auf `cdn.zapstore.dev`, und kind 30063 für 1.0.4 ist nicht auf dem Relay.
- Die APK nicht als Argument übergeben. Dann ignoriert zsp `zapstore.yaml` (pubkey, summary). Die Config im Lauf zeigt auf die heruntergeladene APK und behält den Rest.
- Ohne `--offline` lädt zsp selbst zu Blossom hoch und schreibt auf `wss://relay.zapstore.dev`. Ein zweites Python-Publish ist unnötig; Lauf 40391405904 ist nach einer Sekunde an `No module named 'websockets'` gestorben.
- Danach muss HEAD `https://cdn.zapstore.dev/<sha256>` **200** sein (GET über den Redirect 200 oder 206) und kind 30063 plus kind 3063 für diese Version auf dem Relay liegen. Sonst ist der Job rot, auch wenn zsp 0 geliefert hat.

## Secrets

Namen bleiben:

- `KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`
- `SIGN_WITH` (Bunker-URL `bunker://…`)
- `ZSP_BUNKER_CLIENT_KEY` (64 Hex-Zeichen, derselbe Client-Key wie beim ersten Bunker-Connect, `openssl rand -hex 32`)

## Wenn der Publish rot bleibt

- `zapstore.yaml` mit `pubkey` muss auf dem Branch liegen, den der Workflow auscheckt. Das Relay liest die Datei und whitelistet die npub. Die Datei ist im Repo.
- `cdn.zapstore.dev` kann den Upload trotzdem ablehnen (Reputation / Whitelist). zsp meldet dann `unauthorized` bzw. `whitelist` und der Job wird rot. Liefert zsp trotzdem 0, fängt die CDN-Prüfung den 404 ab. Die npub `npub1hsrqgwepcd9t3t5q9nm2jjvvz626sk6fjhzyqw3ahfpgrz67034sldsnpz` muss auf dem CDN hochladen dürfen. Danach **Publish to ZAPstore** für denselben Tag erneut starten, ohne die Version anzuheben.
- `--skip-certificate-linking` bleibt an: das APK-Zertifikat ist über die Versionen gleich, der Proof ist einmalig. Fehlt er, lokal einmal `zsp identity --link-key` mit dem Keystore ausführen.
