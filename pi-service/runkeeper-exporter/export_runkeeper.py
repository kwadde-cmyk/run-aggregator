#!/usr/bin/env python3
"""
Runkeeper Export Downloader for Raspberry Pi (headless).

Uses the classic export form and downloads the S3 ZIP via Chromium.
Rewrites path-style S3 URLs to virtual-hosted style to avoid TLS SNI issues.

Loads session from cookies.json.

Usage:
  python3 export_runkeeper.py --days 10
"""

import argparse
import asyncio
import json
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import urlparse

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


def to_virtual_hosted(url: str) -> str:
    """Convert path-style S3 URL to virtual-hosted style."""
    parsed = urlparse(url)
    if parsed.netloc == "s3.amazonaws.com" and parsed.path.startswith("/"):
        parts = parsed.path.lstrip("/").split("/", 1)
        if len(parts) == 2:
            bucket, key = parts
            return f"https://{bucket}.s3.amazonaws.com/{key}"
    return url


async def main(days: int = 10):
    cookies = load_cookies()
    print(f"Loaded {len(cookies)} cookies")

    end = datetime.utcnow().date()
    start = end - timedelta(days=days)
    start_str = start.strftime("%d-%b-%y")
    end_str = end.strftime("%d-%b-%y")
    print(f"Requesting export {start_str} → {end_str}")

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

        await page.fill("#startDate", start_str)
        await page.fill("#endDate", end_str)
        print("Submitting classic export form...")
        await page.click("#classicExportForm button[type='submit']")

        print("Waiting for S3 download link...")
        download_href = None
        for attempt in range(60):
            await page.wait_for_timeout(5000)
            try:
                await page.reload(wait_until="domcontentloaded")
            except Exception:
                pass

            link = await page.query_selector("a.btn-secondary:has-text('Download Now')")
            if link:
                href = await link.get_attribute("href") or ""
                if "s3.amazonaws.com" in href and ".zip" in href:
                    download_href = href
                    print(f"Found after ~{(attempt + 1) * 5}s: {href}")
                    break
            print(f"  waiting... ({(attempt + 1) * 5}s)")

        if not download_href:
            print("No S3 ZIP link found.")
            await browser.close()
            return

        # Rewrite to virtual-hosted style (avoids path-style SNI issues)
        vh_url = to_virtual_hosted(download_href)
        print(f"Downloading (virtual-hosted): {vh_url}")

        # Try Chromium request first
        try:
            response = await context.request.get(vh_url, timeout=180000)
            body = await response.body()
            print(f"Request status: {response.status}, size: {len(body)}")
            if response.status == 200 and len(body) > 1000 and body[:2] == b"PK":
                filename = DOWNLOAD_DIR / f"runkeeper-export-{start}-{end}.zip"
                filename.write_bytes(body)
                print(f"Saved: {filename}")
                await browser.close()
                return
        except Exception as e:
            print(f"Request failed: {e}")

        # Fallback: navigate and capture download
        print("Fallback: page navigation + download capture...")
        try:
            async with page.expect_download(timeout=120000) as dl_info:
                await page.goto(vh_url)
            download = await dl_info.value
            filename = DOWNLOAD_DIR / f"runkeeper-export-{start}-{end}.zip"
            await download.save_as(filename)
            print(f"Saved via download: {filename}")
        except Exception as e:
            print(f"Download capture failed: {e}")

        await browser.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=10, help="Days to export")
    args = parser.parse_args()

    asyncio.run(main(days=args.days))
