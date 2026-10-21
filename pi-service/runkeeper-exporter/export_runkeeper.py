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

        # Click Start Export / Export Data
        clicked = False
        for selector in [
            "button:has-text('Start Export')",
            "button:has-text('Export Data')",
            "a:has-text('Start Export')",
            "button:has-text('Export')",
        ]:
            el = await page.query_selector(selector)
            if el:
                print(f"Clicking: {selector}")
                # Start listening for download before click
                async with page.expect_download(timeout=180000) as download_info:
                    await el.click()
                download = await download_info.value
                end = datetime.utcnow().date()
                start = end - timedelta(days=days)
                filename = DOWNLOAD_DIR / f"runkeeper-export-{start}-{end}.zip"
                await download.save_as(filename)
                print(f"Downloaded: {filename}")
                clicked = True
                break

        if not clicked:
            print("No export button found.")
            # Dump more info
            buttons = await page.query_selector_all("button, a, input[type='submit']")
            for i, btn in enumerate(buttons[:20]):
                text = (await btn.inner_text() or "").strip()
                if text:
                    print(f"  [{i}] {text[:80]}")

        await browser.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=10, help="Days to export")
    args = parser.parse_args()

    asyncio.run(main(days=args.days))
