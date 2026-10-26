#!/usr/bin/env python3
"""Fail a ZAPstore publish unless the APK is an update and is actually live.

zsp v0.4.17 can exit 0 after the relay answers OK while the listing stays
pending. `--quiet` skips certificate linking, and relay v2 only promotes a
listing when an active kind 30509 ties the APK signing cert to the publisher.
Until then the CDN returns 404 and kind 30063/3063 are not queryable.
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
PUBLISHER_HEX = "bc06043b21c34ab8ae802cf6a9498c1695a85b4995c4403a3dba42818b5e7c6b"
# Longer than the old 3x5s loop. Promotion after an accepted upload is not instant.
CDN_ATTEMPTS = 8
CDN_RETRY_SECONDS = 15
LINK_KEY_COMMAND = (
    "KEYSTORE_PASSWORD='…' KEYSTORE_KEY_PASSWORD='…' SIGN_WITH='bunker://…' "
    "zsp identity --link-key ~/run-aggregator.keystore "
    "--key-alias runaggregator --relays wss://relay.zapstore.dev"
)
# The relay reads repository + pubkey from the public repo to whitelist.
EXPECTED_REPOSITORY = "https://github.com/kwadde-cmyk/run-aggregator"
EXPECTED_RELEASE_SOURCE = "./build/app/outputs/flutter-apk/app-release.apk"
EXPECTED_WEBSITE = EXPECTED_REPOSITORY

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
    if got != PUBLISHER_HEX:
        raise SystemExit(f"npub self-test failed: {got} != {PUBLISHER_HEX}")
    print(f"npub self-test ok ({got})")
    now = 1_700_000_000
    cert = "ab" * 32
    active = {
        "kind": 30509,
        "pubkey": PUBLISHER_HEX,
        "id": "aa",
        "created_at": now - 10,
        "tags": [["d", cert.upper()], ["expiry", str(now + 100)], ["signature", "x"]],
    }
    expired = {
        "kind": 30509,
        "pubkey": PUBLISHER_HEX,
        "id": "bb",
        "created_at": now - 100,
        "tags": [["d", cert], ["expiry", str(now - 1)]],
    }
    revoked = {
        "kind": 30509,
        "pubkey": PUBLISHER_HEX,
        "id": "cc",
        "created_at": now - 10,
        "tags": [["d", cert], ["expiry", str(now + 50)], ["revoked", "rotated"]],
    }
    event, state, _detail = classify_identity_proofs(
        [expired, revoked, active], pubkey=PUBLISHER_HEX, cert=cert, now=now
    )
    if state != "active" or event is None or event.get("id") != "aa":
        raise SystemExit(f"active identity proof was not selected: {state} {event}")
    _event, state, detail = classify_identity_proofs(
        [expired], pubkey=PUBLISHER_HEX, cert=cert, now=now
    )
    if state != "missing" or "expired" not in detail:
        raise SystemExit(f"expired proof was not rejected: {state} {detail}")
    _event, state, detail = classify_identity_proofs(
        [revoked], pubkey=PUBLISHER_HEX, cert=cert, now=now
    )
    if state != "missing" or "revoked" not in detail:
        raise SystemExit(f"revoked proof was not rejected: {state} {detail}")
    _event, state, detail = classify_identity_proofs(
        [], pubkey=PUBLISHER_HEX, cert=cert, now=now
    )
    if state != "missing" or "zsp identity --link-key" not in detail:
        raise SystemExit(f"missing proof was not rejected: {state} {detail}")
    print("identity proof self-test ok")


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


def check_zapstore_yaml(path: Path) -> str:
    """Return the publisher hex. The relay whitelists from this committed file."""
    repository = yaml_scalar(path, "repository")
    if repository != EXPECTED_REPOSITORY:
        raise SystemExit(
            f"{path}: repository is {repository!r}, want {EXPECTED_REPOSITORY!r}. "
            "The relay reads this URL from the public repo to whitelist the publisher."
        )
    website = yaml_scalar(path, "website")
    if website != EXPECTED_WEBSITE:
        raise SystemExit(f"{path}: website is {website!r}, want {EXPECTED_WEBSITE!r}")
    release_source = yaml_scalar(path, "release_source")
    if release_source != EXPECTED_RELEASE_SOURCE:
        raise SystemExit(
            f"{path}: release_source is {release_source!r}, want "
            f"{EXPECTED_RELEASE_SOURCE!r}. Publish the committed zapstore.yaml. "
            "Do not pass an .apk path to zsp; that drops pubkey."
        )
    name = yaml_scalar(path, "name")
    summary = yaml_scalar(path, "summary")
    icon = yaml_scalar(path, "icon")
    icon_path = (path.parent / icon).resolve()
    if not icon_path.is_file():
        raise SystemExit(f"{path}: icon {icon} is not a file ({icon_path})")
    npub = yaml_scalar(path, "pubkey")
    pubkey = decode_npub(npub)
    if pubkey != PUBLISHER_HEX:
        raise SystemExit(
            f"{path}: pubkey decodes to {pubkey}, want {PUBLISHER_HEX}. "
            "The kind 30509 proof and the release events must share this author."
        )
    print(f"zapstore.yaml name={name!r} summary={summary!r}")
    print(f"zapstore.yaml repository={repository}")
    print(f"zapstore.yaml release_source={release_source}")
    print(f"zapstore.yaml icon={icon}")
    print(f"publisher npub={npub}")
    print(f"publisher hex={pubkey}")
    return pubkey


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


def _utc(timestamp: int) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(timestamp))


def classify_identity_proofs(
    events: list[dict],
    *,
    pubkey: str,
    cert: str,
    now: int,
    relay: str = RELAY,
) -> tuple[dict | None, str, str]:
    """Pick an active kind 30509, or explain why none qualifies.

    Returns (event, state, detail). state is "active" or "missing".
    """
    cert = cert.lower()
    active: list[tuple[int, dict]] = []
    expired: list[str] = []
    revoked: list[str] = []
    for event in events:
        if event.get("kind") not in (None, 30509):
            continue
        if event.get("pubkey") != pubkey:
            continue
        expiry_raw = None
        d_values: list[str] = []
        is_revoked = False
        revoke_reason = ""
        for tag in event.get("tags") or []:
            if not isinstance(tag, list) or not tag:
                continue
            if tag[0] == "d" and len(tag) >= 2:
                d_values.append(str(tag[1]).lower())
            elif tag[0] == "expiry" and len(tag) >= 2 and expiry_raw is None:
                expiry_raw = tag[1]
            elif tag[0] == "revoked":
                is_revoked = True
                if len(tag) >= 2:
                    revoke_reason = str(tag[1])
        if cert not in d_values:
            continue
        event_id = str(event.get("id") or "?")
        if is_revoked:
            revoked.append(f"{event_id} ({revoke_reason})" if revoke_reason else event_id)
            continue
        try:
            expiry = int(expiry_raw)
        except (TypeError, ValueError):
            expired.append(f"{event_id} has no integer expiry tag")
            continue
        created = event.get("created_at")
        if created is not None:
            try:
                if expiry <= int(created):
                    expired.append(f"{event_id} expiry is not after created_at")
                    continue
            except (TypeError, ValueError):
                pass
        if expiry <= now:
            expired.append(f"{event_id} expired {_utc(expiry)}")
            continue
        active.append((expiry, event))
    if active:
        expiry, event = max(active, key=lambda item: item[0])
        return (
            event,
            "active",
            f"kind 30509 active id={event.get('id')} cert={cert} "
            f"pubkey={pubkey} expires {_utc(expiry)}",
        )
    if expired:
        extra = "Existing proof is not active: " + "; ".join(expired) + "."
    elif revoked:
        extra = "Existing proof is revoked: " + "; ".join(revoked) + "."
    else:
        extra = (
            f"The relay returned no kind 30509 with authors=[{pubkey}] and #d=[{cert}]."
        )
    detail = (
        f"No active kind 30509 on {relay} linking APK cert {cert} to pubkey {pubkey}. "
        f"{extra} "
        "zsp v0.4.17 with --quiet skips certificate linking "
        "(checkAndLinkCertificate returns without a proof). "
        "Relay v2 keeps the app, release, and asset events pending until an active "
        "kind 30509 exists: the CDN stays 404 (blob not found) and kind 30063/3063 "
        "are not queryable. Pending listings expire after about 5 hours. "
        "Create the proof once locally (valid 1 year, renew yearly), then re-run "
        "Publish to ZAPstore for the same tag: "
        f"{LINK_KEY_COMMAND}"
    )
    return None, "missing", detail


def actions_error(message: str) -> None:
    print("::error::" + " ".join(message.split()))


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


def check_cdn(sha256: str, cdn: str) -> tuple[bool, str, str, str]:
    """HEAD and a one-byte GET, retried while the listing may still be pending."""
    url = f"{cdn.rstrip('/')}/{sha256}"
    head = ""
    final = ""
    for attempt in range(1, CDN_ATTEMPTS + 1):
        print(f"CDN attempt {attempt}/{CDN_ATTEMPTS}: checking {url}", flush=True)
        head = curl_code(url, ["-I"])
        final = curl_code(url, ["-L", "-r", "0-0"])
        print(f"CDN HEAD {head} {url}", flush=True)
        print(
            f"CDN GET  {final} {url} (redirects followed, first byte only)",
            flush=True,
        )
        if head == "200" and final in ("200", "206"):
            return True, head, final, url
        if attempt < CDN_ATTEMPTS:
            print(
                f"CDN blob not ready (HEAD {head}), retrying in {CDN_RETRY_SECONDS}s",
                flush=True,
            )
            time.sleep(CDN_RETRY_SECONDS)
    return False, head, final, url


def cdn_failure_message(head: str, final: str, url: str, cdn: str, proof_detail: str) -> list[str]:
    waited = f"after {CDN_ATTEMPTS} attempts, {CDN_RETRY_SECONDS}s apart"
    if head == "200" and final not in ("200", "206"):
        return [
            f"Downloading the APK failed (HTTP {final} for {url}) {waited}. "
            "HEAD can succeed while the redirect target is missing. "
            f"{proof_detail}"
        ]
    if head in ("401", "403"):
        return [
            f"APK blob was refused by {cdn} (HEAD {head} for {url}) {waited}. "
            "A 401/403 means this npub cannot PUT to the CDN. "
            "zapstore.yaml whitelists the relay, not the CDN. "
            f"{proof_detail}"
        ]
    return [
        f"APK blob is not on {cdn} (HEAD {head} for {url}) {waited}. "
        f"{proof_detail}"
    ]


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


def query_identity_proof(relay: str, pubkey: str, cert: str) -> tuple[dict | None, str, str]:
    filters = {
        "identity": {
            "kinds": [30509],
            "authors": [pubkey],
            "#d": [cert],
            "limit": 20,
        }
    }
    last_error = "no attempt"
    for attempt in range(1, 4):
        try:
            found = asyncio.run(_relay_query(relay, filters))
        except Exception as exc:  # connection, timeout, bad frame
            last_error = str(exc)
            print(f"kind 30509 query attempt {attempt} failed: {exc}", flush=True)
            if attempt < 3:
                time.sleep(5)
            continue
        return classify_identity_proofs(
            found["identity"], pubkey=pubkey, cert=cert, now=int(time.time()), relay=relay
        )
    return (
        None,
        "unreachable",
        f"Could not query {relay} for kind 30509 "
        f"(authors=[{pubkey}] #d=[{cert}]): {last_error}. "
        "Refusing to treat the certificate link as present.",
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--metadata", type=Path, help="JSON from `zsp utils extract-apk`")
    parser.add_argument("--package")
    parser.add_argument("--version-name")
    parser.add_argument("--version-code", type=int)
    parser.add_argument("--sha256")
    parser.add_argument(
        "--cert-fingerprint",
        help="APK signing cert SHA-256 from `zsp utils extract-apk` (cert_fingerprint)",
    )
    parser.add_argument("--tag", help="Git tag, e.g. v1.0.5")
    parser.add_argument("--expected-version-name")
    parser.add_argument("--expected-version-code", type=int)
    parser.add_argument("--min-version-code", type=int, default=MIN_VERSION_CODE)
    parser.add_argument("--zapstore-yaml", type=Path)
    parser.add_argument("--skip-network", action="store_true")
    parser.add_argument(
        "--require-identity-proof",
        action="store_true",
        help="Query kind 30509 and exit. Run this before zsp publish.",
    )
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
    cert = args.cert_fingerprint
    if args.metadata:
        meta = load_metadata(args.metadata)
        package = package or meta["package_id"]
        version_name = version_name or meta["version_name"]
        if version_code is None:
            version_code = int(meta["version_code"])
        sha256 = sha256 or meta.get("sha256")
        cert = cert or meta.get("cert_fingerprint")
    if cert:
        cert = str(cert).strip().lower()

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
    pubkey = ""
    if args.zapstore_yaml is not None:
        pubkey = check_zapstore_yaml(args.zapstore_yaml)
    if args.require_identity_proof:
        if args.skip_network:
            raise SystemExit("--require-identity-proof cannot be combined with --skip-network")
        if not pubkey:
            raise SystemExit("--zapstore-yaml is required to know the kind 30509 author")
        if not cert or len(cert) != 64 or any(c not in "0123456789abcdef" for c in cert):
            raise SystemExit(
                "cert_fingerprint must be 64 hex chars from `zsp utils extract-apk` "
                f"(got {cert!r})"
            )
        _event, state, detail = query_identity_proof(args.relay, pubkey, cert)
        print(detail)
        if state != "active":
            actions_error(detail)
            return 1
        print("identity proof ok")
        return 0
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

    on_cdn, head, final, cdn_url = check_cdn(sha256, args.cdn)
    errors: list[str] = []
    if not on_cdn:
        if cert and len(cert) == 64:
            _event, state, detail = query_identity_proof(args.relay, pubkey, cert)
            if state == "active":
                detail = (
                    f"{detail} The identity proof is active, so this 404 is the relay "
                    "still holding the listing pending (CDN 'blob not found') or a blob "
                    "that was not stored. Pending listings are not queryable as kind "
                    "30063/3063 and expire after about 5 hours. Re-run Publish to "
                    "ZAPstore for this tag once the listing is promoted."
                )
            elif state == "unreachable":
                detail = (
                    f"{detail} Run 40412044876 showed the other cause: zsp got relay OK "
                    "and the upload was accepted, but without an active kind 30509 the "
                    "relay keeps the listing pending (CDN 404 'blob not found', no "
                    "queryable kind 30063/3063) for about 5 hours."
                )
        else:
            detail = (
                "No cert_fingerprint was available to query kind 30509. "
                "Relay v2 keeps listings pending, CDN 404 'blob not found', until an "
                "active kind 30509 links the APK signing cert to "
                f"{pubkey}. Create it with: {LINK_KEY_COMMAND}"
            )
        errors.extend(cdn_failure_message(head, final, cdn_url, args.cdn, detail))
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
            actions_error(error)
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
