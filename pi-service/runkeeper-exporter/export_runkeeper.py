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
        await page.wait_for_timeout(3000)

        print("Current URL:", page.url)
        content = await page.content()
        print("--- Page snippet ---")
        print(content[:3000])
        print("--- End snippet ---")

        # Try to find and click any export-related button
        buttons = await page.query_selector_all("button, input[type='submit'], a")
        print(f"Found {len(buttons)} clickable elements")
        for i, btn in enumerate(buttons[:15]):
            text = (await btn.inner_text() or "").strip()
            if text:
                print(f"  [{i}] {text[:60]}")

        # Look for Start Export / Export Data
        clicked = False
        for selector in [
            "button:has-text('Start Export')",
            "button:has-text('Export Data')",
            "button:has-text('Export')",
            "a:has-text('Start Export')",
            "input[value*='Export']",
        ]:
            try:
                el = await page.query_selector(selector)
                if el:
                    print(f"Clicking: {selector}")
                    await el.click()
                    clicked = True
                    break
            except Exception:
                pass

        if not clicked:
            print("No export button found. Check the snippet above.")
            await browser.close()
            return

        print("Clicked export. Waiting for download link (up to 2 min)...")
        try:
            # Wait for a download link or button to appear
            await page.wait_for_selector("a:has-text('Download'), button:has-text('Download'), a[href*='.zip']", timeout=120000)
            print("Download element appeared")

            async with page.expect_download(timeout=60000) as download_info:
                await page.click("a:has-text('Download'), button:has-text('Download'), a[href*='.zip']")
            download = await download_info.value
            end = datetime.utcnow().date()
            start = end - timedelta(days=days)
            filename = DOWNLOAD_DIR / f"runkeeper-export-{start}-{end}.zip"
            await download.save_as(filename)
            print(f"Downloaded: {filename}")
        except Exception as e:
            print(f"Download wait failed: {e}")
            print("Final page snippet:")
            print((await page.content())[:2500])

        await browser.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=10, help="Days to export")
    args = parser.parse_args()

    asyncio.run(main(days=args.days))
