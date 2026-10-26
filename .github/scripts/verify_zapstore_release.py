#!/usr/bin/env python3
"""Fail a ZAPstore publish unless the APK is actually an update and is live.

zsp v0.4.17 can exit 0 after writing Nostr events whose Blossom URL 404s.
`--json` also suppresses the per-event relay OK/FAILED lines. This script is
the loud check the workflow runs before and after `zsp publish`.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys
import time
from pathlib import Path

PACKAGE_ID = "de.kwadde.run_aggregator"
# Already shipped on wss://relay.zapstore.dev: 2001 (1.0.0), 2003 (1.0.3),
# 2004 (1.0.4 arm64 split). A lower code can never be an update.
MIN_VERSION_CODE = 2004
CDN = "https://cdn.zapstore.dev"
RELAY = "wss://relay.zapstore.dev"

# BIP-173 bech32. Nostr npubs are 32-byte bech32 (not bech32m).
_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def _polymod(values: list[int]) -> int:
    generator = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for value in values:
        top = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ value
        for i in range(5):
            if (top >> i) & 1:
                chk ^= generator[i]
    return chk


def _hrp_expand(hrp: str) -> list[int]:
    return [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]


def _convertbits(data: list[int], frombits: int, tobits: int, pad: bool) -> list[int] | None:
    acc = 0
    bits = 0
    ret: list[int] = []
    maxv = (1 << tobits) - 1
    max_acc = (1 << (frombits + tobits - 1)) - 1
    for value in data:
        if value < 0 or (value >> frombits):
            return None
        acc = ((acc << frombits) | value) & max_acc
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad:
        if bits:
            ret.append((acc << (tobits - bits)) & maxv)
    elif bits >= frombits or ((acc << (tobits - bits)) & maxv):
        return None
    return ret


def decode_npub(npub: str) -> str:
    """Return the 32-byte hex pubkey from an npub."""
    if npub != npub.lower() and npub != npub.upper():
        raise ValueError(f"mixed-case npub: {npub}")
    npub = npub.lower()
    pos = npub.rfind("1")
    if pos < 1:
        raise ValueError(f"not bech32: {npub}")
    hrp, data_part = npub[:pos], npub[pos + 1 :]
    data = [_CHARSET.find(c) for c in data_part]
    if any(d < 0 for d in data) or len(data) < 6:
        raise ValueError(f"invalid bech32 data in {npub}")
    if _polymod(_hrp_expand(hrp) + data) != 1:
        raise ValueError(f"bad bech32 checksum: {npub}")
    decoded = _convertbits(data[:-6], 5, 8, False)
    if hrp != "npub" or decoded is None or len(decoded) != 32:
        raise ValueError(f"not a 32-byte npub: {npub}")
    return bytes(decoded).hex()


def self_test() -> None:
    # Vector from the signed events already on relay.zapstore.dev.
    got = decode_npub("npub1hsrqgwepcd9t3t5q9nm2jjvvz626sk6fjhzyqw3ahfpgrz67034sldsnpz")
    want = "bc06043b21c34ab8ae802cf6a9498c1695a85b4995c4403a3dba42818b5e7c6b"
    if got != want:
        raise SystemExit(f"npub self-test failed: {got} != {want}")
    print(f"npub self-test ok ({got})")


def yaml_scalar(path: Path, key: str) -> str:
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith(key + ":"):
            value = line.split(":", 1)[1].strip().strip("'").strip('"')
            if not value:
                raise SystemExit(f"{path}: {key} is empty")
            return value
    raise SystemExit(f"{path}: missing {key}")


def load_metadata(path: Path) -> dict:
    data = json.loads(path.read_text())
    for key in ("package_id", "version_name", "version_code", "sha256"):
        if key not in data:
            raise SystemExit(f"{path}: missing {key}")
    return data


def tag_version(tag: str) -> str:
    if not tag.startswith("v") or tag.count(".") != 2:
        raise SystemExit(f"tag must look like v1.0.5, got {tag!r}")
    name = tag[1:]
    parts = name.split(".")
    if not all(part.isdigit() for part in parts):
        raise SystemExit(f"tag must look like v1.0.5, got {tag!r}")
    return name


def check_version(
    *,
    package: str,
    version_name: str,
    version_code: int,
    tag: str | None,
    expected_version_name: str | None,
    expected_version_code: int | None,
    min_version_code: int,
) -> None:
    if package != PACKAGE_ID:
        raise SystemExit(f"package is {package}, want {PACKAGE_ID}")
    if tag is not None and version_name != tag_version(tag):
        raise SystemExit(
            f"APK versionName {version_name} does not match tag {tag} "
            f"({tag_version(tag)})"
        )
    if expected_version_name is not None and version_name != expected_version_name:
        raise SystemExit(
            f"APK versionName {version_name} != pubspec {expected_version_name}"
        )
    if version_code <= min_version_code:
        raise SystemExit(
            f"versionCode {version_code} is not an update. "
            f"ZAPstore already has {min_version_code} (and 2001/2003). "
            f"Raise the +build in pubspec.yaml and build "
            f"a universal APK. Do not use --split-per-abi: Flutter rewrites "
            f"that to ABI*1000+build, so arm64 of +4 became 2004."
        )
    if expected_version_code is not None and version_code != expected_version_code:
        raise SystemExit(
            f"APK versionCode {version_code} != pubspec build number "
            f"{expected_version_code}. The APK was not a universal build. "
            f"--split-per-abi sets arm64 to 2000+build and must not be used."
        )
    print(
        f"version ok: {package} {version_name} versionCode={version_code} "
        f"(> {min_version_code})"
    )


def curl_code(url: str, extra: list[str]) -> str:
    completed = subprocess.run(
        ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", *extra, "--", url],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        timeout=90,
    )
    code = completed.stdout.strip()
    if not code:
        raise SystemExit(f"curl produced no status for {url} (exit {completed.returncode})")
    return code


def check_cdn(sha256: str, cdn: str) -> list[str]:
    url = f"{cdn.rstrip('/')}/{sha256}"
    errors: list[str] = []
    for attempt in range(1, 4):
        print(f"CDN attempt {attempt}: checking {url}")
        head = curl_code(url, ["-I"])
        final = curl_code(url, ["-L", "-r", "0-0"])
        print(f"CDN HEAD {head} {url}")
        print(f"CDN GET  {final} {url} (redirects followed, first byte only)")
        if head == "200" and final in ("200", "206"):
            return []
        if attempt < 3:
            print("CDN blob not ready, retrying")
            time.sleep(5)
    if head != "200":
        errors.append(
            f"APK blob is not on {cdn} (HEAD {head} for {url}). "
            "zsp v0.4.17 publishes the Nostr events before the Blossom upload "
            "and can still exit 0 when the blob is missing. A 401/403, or a "
            "log line 'unauthorized' / 'whitelist', means this npub cannot PUT "
            "to the CDN. zapstore.yaml whitelists the relay, not the CDN. "
            "After the npub is allowed to upload, re-run Publish to ZAPstore "
            "for the same tag."
        )
    if final not in ("200", "206"):
        errors.append(
            f"Downloading the APK failed (HTTP {final} for {url}). "
            "HEAD can succeed while the redirect target is missing."
        )
    return errors


def _tags(event: dict) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for tag in event.get("tags", []):
        if len(tag) >= 2:
            found.setdefault(tag[0], []).append(tag[1])
    return found


async def _relay_query(relay: str, filters: dict[str, dict]) -> dict[str, list[dict]]:
    import websockets

    events: dict[str, list[dict]] = {name: [] for name in filters}
    pending = set(filters)
    async with websockets.connect(relay, open_timeout=20, close_timeout=5) as ws:
        for name, filt in filters.items():
            payload = json.dumps(["REQ", name, filt])
            print(f"RELAY REQ {payload}")
            await ws.send(payload)
        while pending:
            raw = await asyncio.wait_for(ws.recv(), timeout=25)
            print(f"RELAY MSG {raw}")
            msg = json.loads(raw)
            if not msg:
                continue
            kind = msg[0]
            if kind == "EOSE" and len(msg) > 1:
                pending.discard(msg[1])
            elif kind == "EVENT" and len(msg) > 2 and msg[1] in events:
                events[msg[1]].append(msg[2])
            elif kind in ("NOTICE", "OK", "AUTH", "CLOSED"):
                print(f"RELAY {kind}: {msg}")
    return events


def check_relay(
    *,
    relay: str,
    pubkey: str,
    package: str,
    version_name: str,
    version_code: int,
    sha256: str,
    cdn: str,
) -> list[str]:
    filters = {
        "release": {
            "kinds": [30063],
            "authors": [pubkey],
            "#d": [f"{package}@{version_name}"],
            "limit": 5,
        },
        "asset": {
            "kinds": [3063],
            "authors": [pubkey],
            "#x": [sha256],
            "limit": 5,
        },
    }
    try:
        found = asyncio.run(_relay_query(relay, filters))
    except Exception as exc:  # connection, timeout, bad frame
        return [f"relay query failed: {exc}"]

    errors: list[str] = []
    release_ok = False
    for event in found["release"]:
        tags = _tags(event)
        pubkey_ok = event.get("pubkey") == pubkey
        d_ok = f"{package}@{version_name}" in tags.get("d", [])
        version_ok = version_name in tags.get("version", [])
        print(
            f"kind 30063 id={event.get('id')} pubkey_ok={pubkey_ok} "
            f"d={tags.get('d')} version={tags.get('version')}"
        )
        if pubkey_ok and d_ok and version_ok:
            release_ok = True
    if not release_ok:
        errors.append(
            f"no kind 30063 on {relay} for {package}@{version_name} "
            f"from {pubkey}. The app-page event (kind 32267) can update "
            f"while the release event is rejected."
        )

    asset_ok = False
    for event in found["asset"]:
        tags = _tags(event)
        pubkey_ok = event.get("pubkey") == pubkey
        hash_ok = sha256 in tags.get("x", [])
        package_ok = package in tags.get("i", [])
        version_ok = version_name in tags.get("version", [])
        code_ok = str(version_code) in tags.get("version_code", [])
        urls = tags.get("url", [])
        url_ok = any(sha256 in url and cdn.split("://", 1)[-1] in url for url in urls)
        print(
            f"kind 3063 id={event.get('id')} pubkey_ok={pubkey_ok} "
            f"version_code={tags.get('version_code')} url={urls} "
            f"hash_ok={hash_ok} url_ok={url_ok}"
        )
        if pubkey_ok and hash_ok and package_ok and version_ok and code_ok and url_ok:
            asset_ok = True
    if not asset_ok:
        errors.append(
            f"no kind 3063 on {relay} for sha256 {sha256} "
            f"(package {package}, version {version_name}, "
            f"versionCode {version_code}) whose url points at the CDN."
        )
    return errors


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--metadata", type=Path, help="JSON from `zsp utils extract-apk`")
    parser.add_argument("--package")
    parser.add_argument("--version-name")
    parser.add_argument("--version-code", type=int)
    parser.add_argument("--sha256")
    parser.add_argument("--tag", help="Git tag, e.g. v1.0.5")
    parser.add_argument("--expected-version-name")
    parser.add_argument("--expected-version-code", type=int)
    parser.add_argument("--min-version-code", type=int, default=MIN_VERSION_CODE)
    parser.add_argument("--zapstore-yaml", type=Path)
    parser.add_argument("--skip-network", action="store_true")
    parser.add_argument("--cdn", default=CDN)
    parser.add_argument("--relay", default=RELAY)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    self_test()
    if args.self_test:
        return 0

    package = args.package
    version_name = args.version_name
    version_code = args.version_code
    sha256 = args.sha256
    if args.metadata:
        meta = load_metadata(args.metadata)
        package = package or meta["package_id"]
        version_name = version_name or meta["version_name"]
        if version_code is None:
            version_code = int(meta["version_code"])
        sha256 = sha256 or meta["sha256"]

    missing = [
        name
        for name, value in (
            ("package", package),
            ("version-name", version_name),
            ("version-code", version_code),
        )
        if value is None or value == ""
    ]
    if missing:
        raise SystemExit(f"missing {', '.join(missing)} (or --metadata)")

    check_version(
        package=package,
        version_name=version_name,
        version_code=int(version_code),
        tag=args.tag,
        expected_version_name=args.expected_version_name,
        expected_version_code=args.expected_version_code,
        min_version_code=args.min_version_code,
    )
    if args.skip_network:
        print("network checks skipped")
        return 0
    if not sha256:
        raise SystemExit("sha256 is required for the CDN and relay checks")
    sha256 = sha256.lower()
    if len(sha256) != 64 or any(c not in "0123456789abcdef" for c in sha256):
        raise SystemExit(f"sha256 must be 64 hex chars, got {sha256!r}")
    if args.zapstore_yaml is None:
        raise SystemExit("--zapstore-yaml is required for the relay check")

    npub = yaml_scalar(args.zapstore_yaml, "pubkey")
    pubkey = decode_npub(npub)
    print(f"publisher npub={npub}")
    print(f"publisher hex={pubkey}")

    errors = check_cdn(sha256, args.cdn)
    errors.extend(
        check_relay(
            relay=args.relay,
            pubkey=pubkey,
            package=package,
            version_name=version_name,
            version_code=int(version_code),
            sha256=sha256,
            cdn=args.cdn,
        )
    )
    if errors:
        print("verification failed:")
        for error in errors:
            print(f"- {error}")
        return 1
    print("ZAPstore verification ok: CDN and relay both have this APK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as exc:
        print(f"verification error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
