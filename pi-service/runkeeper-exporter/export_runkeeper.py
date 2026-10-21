#!/usr/bin/env python3
"""
Runkeeper Export Downloader for Raspberry Pi (headless).

Loads session from cookies.json (exported from browser).

Usage:
  python3 export_runkeeper.py --days 10
"""

import argparse
import asyncio
import json
from datetime import datetime, timedelta
from pathlib import Path

import requests
from playwright.async_api import async_playwright

COOKIES_FILE = Path(__file__).parent / "cookies.json"
DOWNLOAD_DIR = Path.home() / "runkeeper-exports"
DOWNLOAD_DIR.mkdir(exist_ok=True)


def load_cookies():
    if not COOKIES_FILE.exists():
        raise FileNotFoundError(f"{COOKIES_FILE} not found. Export cookies from your browser.")
    with open(COOKIES_FILE) as f:
        raw = json.load(f)
    cookies = []
    for c in raw:
        cookie = {
            "name": c.get("name") or c.get("Name"),
            "value": c.get("value") or c.get("Value"),
            "domain": c.get("domain") or c.get("Domain") or ".runkeeper.com",
            "path": c.get("path") or c.get("Path") or "/",
        }
        if cookie["name"] and cookie["value"]:
            cookies.append(cookie)
    return cookies


async def main(days: int = 10):
    cookies = load_cookies()
    print(f"Loaded {len(cookies)} cookies")

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
        )
        context = await browser.new_context(accept_downloads=True)
        await context.add_cookies(cookies)

        page = await context.new_page()

        print("Opening export page...")
        await page.goto("https://runkeeper.com/exportData", wait_until="networkidle")
        await page.wait_for_timeout(2000)
        print("Current URL:", page.url)

        # Click Start Export
        start_btn = await page.query_selector("button:has-text('Start Export'), button:has-text('Export Data'), a:has-text('Start Export')")
        if not start_btn:
            print("Start Export button not found")
            await browser.close()
            return

        print("Clicking Start Export...")
        await start_btn.click()
        print("Waiting for export to be prepared (up to 4 min)...")

        # Poll for a real download link (href containing .zip or download)
        download_href = None
        for attempt in range(48):
            await page.wait_for_timeout(5000)
            try:
                await page.reload(wait_until="domcontentloaded")
            except Exception:
                pass

            # Look for links that look like actual file downloads
            links = await page.query_selector_all("a[href]")
            for link in links:
                href = await link.get_attribute("href") or ""
                text = (await link.inner_text() or "").lower()
                if any(x in href.lower() for x in [".zip", "download", "export"]) or "download" in text:
                    if href and href != "/exportData" and "exportData" not in href:
                        download_href = href
                        print(f"Candidate link: {href} (text: {text[:40]})")
                        break
            if download_href:
                print(f"Download link found after ~{(attempt+1)*5}s")
                break
            print(f"  still waiting... ({(attempt+1)*5}s)")

        if not download_href:
            print("No suitable download link found. Dumping all links:")
            links = await page.query_selector_all("a[href]")
            for link in links[:30]:
                href = await link.get_attribute("href") or ""
                text = (await link.inner_text() or "").strip()[:50]
                if href:
                    print(f"  {text} -> {href}")
            print("--- Page snippet ---")
            print((await page.content())[:4000])
            await browser.close()
            return

        # Normalize href
        if download_href.startswith("/"):
            download_href = "https://runkeeper.com" + download_href
        print(f"Downloading from: {download_href}")

        # Use requests with the same cookies
        pw_cookies = await context.cookies()
        session = requests.Session()
        for c in pw_cookies:
            session.cookies.set(c["name"], c["value"], domain=c.get("domain") or "")

        r = session.get(download_href, allow_redirects=True, timeout=120)
        print(f"Download status: {r.status_code}, size: {len(r.content)} bytes, content-type: {r.headers.get('content-type')}")

        if r.status_code == 200 and len(r.content) > 5000 and (r.content[:2] == b'PK' or 'zip' in r.headers.get('content-type', '').lower()):
            end = datetime.utcnow().date()
            start = end - timedelta(days=days)
            filename = DOWNLOAD_DIR / f"runkeeper-export-{start}-{end}.zip"
            filename.write_bytes(r.content)
            print(f"Saved: {filename}")
        else:
            print("Not a valid ZIP. Response snippet:")
            print(r.text[:800] if r.text else r.content[:200])

        await browser.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=10, help="Days to export")
    args = parser.parse_args()

    asyncio.run(main(days=args.days))
