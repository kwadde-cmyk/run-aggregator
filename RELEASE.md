# Release-APK bauen (ZAPstore)

Schritt-für-Schritt für die signierte Release-APK.

## 1. Keystore anlegen (einmalig)

Auf deinem Rechner:

```bash
keytool -genkey -v -keystore ~/run-aggregator.keystore \
  -alias runaggregator -keyalg RSA -keysize 2048 -validity 10000
```

Du wirst nach einem Passwort und einigen Daten (Name, Ort, …) gefragt.  
**Merke dir das Passwort** – es wird für jeden Release-Build gebraucht.

## 2. SHA-1 auslesen

```bash
keytool -list -v -keystore ~/run-aggregator.keystore -alias runaggregator
```

In der Ausgabe findest du eine Zeile wie:

```
SHA1: AA:BB:CC:DD:...
```

Kopiere den SHA1-Wert (mit Doppelpunkten).

## 3. SHA-1 in Google Cloud eintragen

1. Öffne [Google Cloud Console](https://console.cloud.google.com/)
2. Projekt `ernaehrungscoach-1791139635683` auswählen
3. APIs & Services → Credentials
4. Deinen OAuth-Client (Android) öffnen  
   (falls noch keiner existiert: Create Credentials → OAuth client ID → Android)
5. Package name: `de.kwadde.run_aggregator`
6. SHA-1 fingerprint: den Wert aus Schritt 2 einfügen
7. Speichern

Ohne diesen Schritt schlägt der Google-Login in der signierten APK fehl.

## 4. key.properties anlegen

```bash
cd ~/run-aggregator
cp android/key.properties.example android/key.properties
nano android/key.properties
```

Trage deine Passwörter und den Pfad zum Keystore ein:

```
storePassword=dein_passwort
keyPassword=dein_passwort
keyAlias=runaggregator
storeFile=/home/kwadde/run-aggregator.keystore
```

## 5. Signing in build.gradle.kts aktivieren

Öffne `android/app/build.gradle.kts` und stelle sicher, dass oben steht:

```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
```

Und im `android { … }` Block:

```kotlin
signingConfigs {
    create("release") {
        keyAlias = keystoreProperties["keyAlias"] as String?
        keyPassword = keystoreProperties["keyPassword"] as String?
        storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
        storePassword = keystoreProperties["storePassword"] as String?
    }
}
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("release")
        isMinifyEnabled = false
    }
}
```

## 6. APK bauen

```bash
cd ~/run-aggregator
flutter build apk --release
```

Ohne `--split-per-abi`. Die APK liegt danach unter:

```
build/app/outputs/flutter-apk/app-release.apk
```

Für ZAPstore zählt der `versionCode` aus `pubspec.yaml` (Zahl nach `+`). Der muss über 2004 liegen. Ablauf: `RELEASING.md`.

## 7. Testen

```bash
flutter install --release
# oder manuell auf das Handy schieben und installieren
```

Beim ersten Start sollte der Google-Login funktionieren (weil der SHA-1 registriert ist).

## 8. ZAPstore

Veröffentlichen und einen fehlgeschlagenen Publish wiederholen: `RELEASING.md`.

## Sicherheit

- `key.properties` und `*.keystore` stehen in `.gitignore`
- Nie ins Repo committen
- Keystore und Passwort sicher aufbewahren – ohne sie kannst du keine Updates signieren
