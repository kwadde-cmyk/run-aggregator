#!/usr/bin/env python3
"""
Runkeeper Export Downloader for Raspberry Pi (headless).

Uses Playwright/Chromium for all network requests so modern TLS works
on older Raspberry Pi OS OpenSSL.

Loads session from cookies.json.

Usage:
  python3 export_runkeeper.py --days 10
"""

import argparse
import asyncio
import json
from datetime import datetime, timedelta
from pathlib import Path

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
        start_btn = await page.query_selector(
            "button:has-text('Start Export'), button:has-text('Export Data'), a:has-text('Start Export')"
        )
        if not start_btn:
            print("Start Export button not found")
            await browser.close()
            return

        print("Clicking Start Export...")
        await start_btn.click()
        print("Waiting for export to be prepared (up to 4 min)...")

        # Poll for a real S3 / ZIP download link
        download_href = None
        for attempt in range(48):
            await page.wait_for_timeout(5000)
            try:
                await page.reload(wait_until="domcontentloaded")
            except Exception:
                pass

            links = await page.query_selector_all("a[href]")
            for link in links:
                href = await link.get_attribute("href") or ""
                text = (await link.inner_text() or "").lower()
                if (".zip" in href.lower() or "s3.amazonaws.com" in href.lower() or "download now" in text):
                    if href and "exportData" not in href:
                        download_href = href
                        print(f"Found: {href}")
                        break
            if download_href:
                print(f"Download link ready after ~{(attempt + 1) * 5}s")
                break
            print(f"  waiting... ({(attempt + 1) * 5}s)")

        if not download_href:
            print("No download link found. Dumping links:")
            for link in await page.query_selector_all("a[href]"):
                href = await link.get_attribute("href") or ""
                text = (await link.inner_text() or "").strip()[:60]
                if href:
                    print(f"  {text} -> {href}")
            await browser.close()
            return

        if download_href.startswith("/"):
            download_href = "https://runkeeper.com" + download_href
        print(f"Downloading via Chromium: {download_href}")

        # Use Chromium's network stack (modern TLS)
        response = await context.request.get(download_href, timeout=180000)
        body = await response.body()
        print(f"Status: {response.status}, size: {len(body)} bytes, type: {response.headers.get('content-type')}")

        if response.status == 200 and len(body) > 5000 and body[:2] == b"PK":
            end = datetime.utcnow().date()
            start = end - timedelta(days=days)
            filename = DOWNLOAD_DIR / f"runkeeper-export-{start}-{end}.zip"
            filename.write_bytes(body)
            print(f"Saved: {filename}")
        else:
            print("Not a valid ZIP.")
            print(body[:300])

        await browser.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=10, help="Days to export")
    args = parser.parse_args()

    asyncio.run(main(days=args.days))
