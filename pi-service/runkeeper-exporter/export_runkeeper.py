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

from playwright.async_api import async_playwright

COOKIES_FILE = Path(__file__).parent / "cookies.json"
DOWNLOAD_DIR = Path.home() / "runkeeper-exports"
DOWNLOAD_DIR.mkdir(exist_ok=True)


def load_cookies():
    if not COOKIES_FILE.exists():
        raise FileNotFoundError(f"{COOKIES_FILE} not found. Export cookies from your browser.")
    with open(COOKIES_FILE) as f:
        raw = json.load(f)
    # Normalize different cookie export formats
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

        # Check if logged in
        await page.goto("https://runkeeper.com/settings", wait_until="domcontentloaded")
        await page.wait_for_timeout(2000)
        if "login" in page.url.lower():
            print("Not logged in. Cookies may be invalid or expired.")
            await browser.close()
            return

        print("Logged in. Going to export page...")
        await page.goto("https://runkeeper.com/exportData", wait_until="domcontentloaded")
        await page.wait_for_timeout(2000)

        # Set date range (last N days)
        end = datetime.utcnow().date()
        start = end - timedelta(days=days)

        try:
            await page.fill("input[name='startDate'], input[placeholder*='Start'], input[id*='start']", start.strftime("%Y-%m-%d"))
            await page.fill("input[name='endDate'], input[placeholder*='End'], input[id*='end']", end.strftime("%Y-%m-%d"))
        except Exception as e:
            print(f"Could not fill date fields: {e}")
            print("Page content snippet:")
            print((await page.content())[:2000])
            await browser.close()
            return

        # Trigger export and download
        try:
            async with page.expect_download(timeout=120000) as download_info:
                await page.click("button:has-text('Export Data'), button:has-text('Export'), input[type='submit']")
            download = await download_info.value
            filename = DOWNLOAD_DIR / f"runkeeper-export-{start}-{end}.zip"
            await download.save_as(filename)
            print(f"Downloaded: {filename}")
        except Exception as e:
            print(f"Export/download failed: {e}")
            print("Current URL:", page.url)
            print("Page snippet:")
            print((await page.content())[:2000])

        await browser.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=10, help="Days to export")
    args = parser.parse_args()

    asyncio.run(main(days=args.days))
