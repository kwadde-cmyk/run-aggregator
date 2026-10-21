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
        print("Waiting for export to be prepared (up to 3 min)...")

        # Poll for a download link
        download_href = None
        for attempt in range(36):
            await page.wait_for_timeout(5000)
            try:
                await page.reload(wait_until="domcontentloaded")
            except Exception:
                pass

            link = await page.query_selector(
                "a:has-text('Download'), a:has-text('Download Now'), a[href*='.zip'], a[href*='export']"
            )
            if link:
                download_href = await link.get_attribute("href")
                print(f"Download link found after ~{(attempt+1)*5}s: {download_href}")
                break
            print(f"  still waiting... ({(attempt+1)*5}s)")

        if not download_href:
            print("No download link appeared. Final page snippet:")
            print((await page.content())[:3000])
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
        print(f"Download status: {r.status_code}, size: {len(r.content)} bytes")

        if r.status_code == 200 and len(r.content) > 1000:
            end = datetime.utcnow().date()
            start = end - timedelta(days=days)
            filename = DOWNLOAD_DIR / f"runkeeper-export-{start}-{end}.zip"
            filename.write_bytes(r.content)
            print(f"Saved: {filename}")
        else:
            print("Download failed or file too small. Response headers:")
            print(dict(r.headers))
            print("Body snippet:", r.text[:500] if r.text else "(binary)")

        await browser.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=10, help="Days to export")
    args = parser.parse_args()

    asyncio.run(main(days=args.days))
