#!/usr/bin/env python3
"""
Runkeeper Export Downloader for Raspberry Pi (headless).

Session is stored in ~/.runkeeper-profile.

First login (do this on a machine with a browser, or use xvfb):
  python3 export_runkeeper.py --login

Or copy an existing profile from another machine.

Then on the Pi:
  python3 export_runkeeper.py --days 10
"""

import argparse
import asyncio
from datetime import datetime, timedelta
from pathlib import Path

from playwright.async_api import async_playwright

PROFILE_DIR = Path.home() / ".runkeeper-profile"
DOWNLOAD_DIR = Path.home() / "runkeeper-exports"
DOWNLOAD_DIR.mkdir(exist_ok=True)


async def main(login_only: bool = False, days: int = 10):
    async with async_playwright() as p:
        context = await p.chromium.launch_persistent_context(
            user_data_dir=str(PROFILE_DIR),
            headless=True,  # always headless on Pi
            accept_downloads=True,
            args=["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
        )

        page = await context.new_page()

        if login_only:
            print("Headless login is not interactive.")
            print("Options:")
            print("  1. Run this script on a desktop with a display first, then copy ~/.runkeeper-profile to the Pi.")
            print("  2. Or install xvfb and run: xvfb-run python3 export_runkeeper.py --login")
            print("  3. Or manually export a cookie/session and place it in the profile.")
            await context.close()
            return

        # Check if logged in
        await page.goto("https://runkeeper.com/settings", wait_until="domcontentloaded")
        await page.wait_for_timeout(2000)
        if "login" in page.url.lower():
            print("Not logged in. You need a valid session profile in ~/.runkeeper-profile")
            print("Do the login on a machine with a GUI and copy the profile folder, or use xvfb-run.")
            await context.close()
            return

        print("Logged in. Going to export page...")
        await page.goto("https://runkeeper.com/exportData", wait_until="domcontentloaded")
        await page.wait_for_timeout(2000)

        # Set date range (last N days)
        end = datetime.utcnow().date()
        start = end - timedelta(days=days)

        # Selectors may need adjustment if the page changes
        try:
            await page.fill("input[name='startDate'], input[placeholder*='Start']", start.strftime("%Y-%m-%d"))
            await page.fill("input[name='endDate'], input[placeholder*='End']", end.strftime("%Y-%m-%d"))
        except Exception as e:
            print(f"Could not fill date fields: {e}")
            print("Page content snippet:")
            print(await page.content()[:1500])
            await context.close()
            return

        # Trigger export and download
        try:
            async with page.expect_download(timeout=120000) as download_info:
                await page.click("button:has-text('Export Data'), button:has-text('Export')")
            download = await download_info.value
            filename = DOWNLOAD_DIR / f"runkeeper-export-{start}-{end}.zip"
            await download.save_as(filename)
            print(f"Downloaded: {filename}")
        except Exception as e:
            print(f"Export/download failed: {e}")
            print("You may need to adjust the button selector. Current URL:", page.url)

        await context.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--login", action="store_true", help="Show login instructions")
    parser.add_argument("--days", type=int, default=10, help="Days to export")
    args = parser.parse_args()

    asyncio.run(main(login_only=args.login, days=args.days))
