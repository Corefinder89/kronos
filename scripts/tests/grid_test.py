"""
grid_test.py — Selenium Grid smoke test

Verifies the Selenium Grid setup by:
  1. Connecting to the remote Grid hub
  2. Opening a browser (Chrome or Firefox) on a worker node
  3. Navigating to a URL and asserting the page title
  4. Printing session/node info for confirmation

Usage:
    # Install dependency
    pip install selenium

    # Run against your Grid
    python grid_test.py --hub <manager-ip> --browser chrome
    python grid_test.py --hub <manager-ip> --browser firefox

    # Run both browsers in parallel
    python grid_test.py --hub <manager-ip> --browser both
"""

import argparse
import sys
import threading
from datetime import datetime

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

TEST_URL   = "https://www.google.com"
SEARCH_TERM = "Selenium Grid"
GRID_PORT  = 4444


# ---------------------------------------------------------------------------
# Test logic
# ---------------------------------------------------------------------------

def run_test(hub_ip: str, browser: str, results: dict) -> None:
    """Open a browser on the Grid, run a basic search, assert results."""

    hub_url = f"http://{hub_ip}:{GRID_PORT}/wd/hub"
    print(f"[{browser}] Connecting to Grid at {hub_url}")

    # Build RemoteWebDriver options
    if browser == "chrome":
        options = webdriver.ChromeOptions()
    elif browser == "firefox":
        options = webdriver.FirefoxOptions()
    else:
        raise ValueError(f"Unsupported browser: {browser}")

    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")

    driver = None
    try:
        driver = webdriver.Remote(
            command_executor=hub_url,
            options=options,
        )

        session_id = driver.session_id
        print(f"[{browser}] Session ID : {session_id}")
        print(f"[{browser}] Node info  : {driver.capabilities.get('se:nodeId', 'N/A')}")

        # --- Navigate ---
        print(f"[{browser}] Navigating to {TEST_URL}")
        driver.get(TEST_URL)

        # --- Assert title ---
        assert "Google" in driver.title, f"Unexpected title: {driver.title}"
        print(f"[{browser}] Page title : {driver.title} ✓")

        # --- Search ---
        wait = WebDriverWait(driver, 10)
        search_box = wait.until(EC.presence_of_element_located((By.NAME, "q")))
        search_box.send_keys(SEARCH_TERM)
        search_box.submit()

        # --- Assert results page ---
        wait.until(EC.title_contains(SEARCH_TERM))
        print(f"[{browser}] Search results title: {driver.title} ✓")

        results[browser] = "PASSED"

    except Exception as exc:
        print(f"[{browser}] FAILED — {exc}", file=sys.stderr)
        results[browser] = f"FAILED: {exc}"

    finally:
        if driver:
            driver.quit()
            print(f"[{browser}] Session closed.")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Selenium Grid smoke test")
    parser.add_argument(
        "--hub",
        required=True,
        help="Public IP of the Swarm manager / Grid hub (e.g. 123.45.67.89)",
    )
    parser.add_argument(
        "--browser",
        choices=["chrome", "firefox", "both"],
        default="chrome",
        help="Browser to test (default: chrome)",
    )
    args = parser.parse_args()

    browsers = ["chrome", "firefox"] if args.browser == "both" else [args.browser]
    results: dict = {}

    print(f"\n{'='*60}")
    print(f"  Kronos — Selenium Grid Smoke Test")
    print(f"  Hub     : {args.hub}:{GRID_PORT}")
    print(f"  Browser : {', '.join(browsers)}")
    print(f"  Time    : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'='*60}\n")

    if len(browsers) == 1:
        run_test(args.hub, browsers[0], results)
    else:
        # Run both browsers in parallel threads
        threads = [
            threading.Thread(target=run_test, args=(args.hub, b, results))
            for b in browsers
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

    # --- Summary ---
    print(f"\n{'='*60}")
    print("  Results")
    print(f"{'='*60}")
    all_passed = True
    for browser, result in results.items():
        status_icon = "✓" if result == "PASSED" else "✗"
        print(f"  {status_icon}  {browser:<10} {result}")
        if result != "PASSED":
            all_passed = False
    print(f"{'='*60}\n")

    sys.exit(0 if all_passed else 1)


if __name__ == "__main__":
    main()
