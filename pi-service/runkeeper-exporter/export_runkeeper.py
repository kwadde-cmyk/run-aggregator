#!/usr/bin/env python3
"""
Runkeeper Export Downloader for Raspberry Pi.

Uses Playwright to log in once (interactive OTP) and then download exports.
Session is persisted in a browser profile.

Usage:
  # First run (interactive login):
  python3 export_runkeeper.py --login

  # Later runs (download last 10 days):
  python3 export_runkeeper.py --days 10
"""

import argparse
import asyncio
import os
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
            headless=not login_only,
            accept_downloads=True,
            args=["--no-sandbox", "--disable-dev-shm-usage"],
        )

        page = await context.new_page()

        if login_only:
            print("Opening Runkeeper login. Complete the email code login in the browser window.")
            await page.goto("https://runkeeper.com/login")
            input("Press Enter after you have successfully logged in...")
            print("Session saved. You can close the browser.")
            await context.close()
            return

        # Check if logged in
        await page.goto("https://runkeeper.com/settings")
        if "login" in page.url:
            print("Not logged in. Run with --login first.")
            await context.close()
            return

        print("Logged in. Going to export page...")
        await page.goto("https://runkeeper.com/exportData")

        # Set date range (last N days)
        end = datetime.utcnow().date()
        start = end - timedelta(days=days)

        # These selectors may need adjustment if Runkeeper changes the page
        await page.fill("input[name='startDate']", start.strftime("%Y-%m-%d"))
        await page.fill("input[name='endDate']", end.strftime("%Y-%m-%d"))

        # Trigger export
        async with page.expect_download() as download_info:
            await page.click("button:has-text('Export Data')")
        download = await download_info.value

        filename = DOWNLOAD_DIR / f"runkeeper-export-{start}-{end}.zip"
        await download.save_as(filename)
        print(f"Downloaded: {filename}")

        await context.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--login", action="store_true", help="Interactive login")
    parser.add_argument("--days", type=int, default=10, help="Days to export")
    args = parser.parse_args()

    asyncio.run(main(login_only=args.login, days=args.days))
