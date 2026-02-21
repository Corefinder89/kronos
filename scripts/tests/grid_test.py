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
import requests
from datetime import datetime

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

TEST_URL   = "https://www.google.com"
SEARCH_TERM = "Selenium Grid"
GRID_PORT  = 4444


def get_node_info(hub_ip: str, capabilities: dict) -> dict:
    """Extract detailed node information by correlating capabilities with Grid status."""
    try:
        # Get Grid node information
        response = requests.get(f"http://{hub_ip}:{GRID_PORT}/status", timeout=5)
        grid_status = response.json()
        nodes = grid_status.get('value', {}).get('nodes', [])
        
        # Extract node IP from CDP endpoint
        cdp_endpoint = capabilities.get('se:cdp', '')
        node_ip = None
        if cdp_endpoint:
            # Extract IP from CDP WebSocket URL (e.g., ws://10.0.1.22:4444/...)
            try:
                node_ip = cdp_endpoint.split('//')[1].split(':')[0]
            except (IndexError, AttributeError):
                pass
        
        # Find matching node by IP
        node_id = "Unknown"
        node_uri = "Unknown"
        for node in nodes:
            try:
                uri = node.get('uri', '')
                if node_ip and node_ip in uri:
                    node_id = node.get('id', 'Unknown')[:8] + '...'  # Short ID
                    node_uri = uri
                    break
            except (AttributeError, TypeError):
                continue
        
        return {
            'node_id': node_id,
            'node_uri': node_uri,
            'node_ip': node_ip or 'Unknown',
            'container': capabilities.get('se:containerName') or f"selenium-{capabilities.get('browserName', 'unknown')}-node",
            'vnc_port': capabilities.get('se:noVncPort', 'Unknown'),
            'vnc_enabled': capabilities.get('se:vncEnabled', False),
            'browser_version': capabilities.get('browserVersion', 'Unknown')
        }
    
    except Exception as e:
        return {
            'node_id': 'Error',
            'node_uri': 'Error', 
            'node_ip': 'Error',
            'container': 'Error',
            'vnc_port': 'Error',
            'vnc_enabled': False,
            'browser_version': 'Error',
            'error': str(e)
        }

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
    options.add_argument("--disable-blink-features=AutomationControlled")
    options.add_argument("--user-agent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
    
    # Set timeouts for better reliability
    options.add_argument("--timeout=30000")
    
    # Chrome-specific options
    if browser == "chrome":
        options.add_experimental_option("useAutomationExtension", False)
        options.add_experimental_option("excludeSwitches", ["enable-automation"])

    driver = None
    try:
        driver = webdriver.Remote(
            command_executor=hub_url,
            options=options,
        )

        session_id = driver.session_id
        print(f"[{browser}] Session ID : {session_id}")
        
        # Extract comprehensive node information
        node_info = get_node_info(hub_ip, driver.capabilities)
        print(f"[{browser}] Node ID    : {node_info['node_id']}")
        print(f"[{browser}] Node IP    : {node_info['node_ip']}")
        print(f"[{browser}] Container  : {node_info['container']}")
        print(f"[{browser}] Browser    : {node_info['browser_version']}")
        if node_info['vnc_enabled']:
            print(f"[{browser}] VNC Port   : {node_info['vnc_port']} (VNC enabled)")
        
        if 'error' in node_info:
            print(f"[{browser}] Node Error : {node_info['error']}")

        # --- Navigate ---
        print(f"[{browser}] Navigating to {TEST_URL}")
        driver.get(TEST_URL)

        # --- Assert title ---
        assert "Google" in driver.title, f"Unexpected title: {driver.title}"
        print(f"[{browser}] Page title : {driver.title} ✓")

        # --- Search (with multiple fallback strategies) ---
        wait = WebDriverWait(driver, 15)
        
        # Try multiple selectors for the search box
        search_selectors = [
            (By.NAME, "q"),
            (By.CSS_SELECTOR, "input[name='q']"),
            (By.CSS_SELECTOR, "textarea[name='q']"),
            (By.CSS_SELECTOR, "[aria-label*='Search']"),
            (By.CSS_SELECTOR, "input[type='search']"),
            (By.CSS_SELECTOR, "#APjFqb")  # Google's current search box ID
        ]
        
        search_box = None
        for selector_type, selector_value in search_selectors:
            try:
                search_box = wait.until(EC.element_to_be_clickable((selector_type, selector_value)))
                print(f"[{browser}] Found search box using selector: {selector_type}={selector_value}")
                break
            except Exception:
                continue
                
        if not search_box:
            raise Exception("Could not locate search input field")
            
        # Clear and enter search term
        search_box.clear()
        search_box.send_keys(SEARCH_TERM)
        
        # Try multiple ways to submit the search
        try:
            # Try pressing Enter first (more reliable)
            from selenium.webdriver.common.keys import Keys
            search_box.send_keys(Keys.RETURN)
            print(f"[{browser}] Search submitted using RETURN key")
        except Exception:
            try:
                # Fallback to submit method
                search_box.submit()
                print(f"[{browser}] Search submitted using submit() method")
            except Exception:
                # Look for search button and click it
                search_buttons = [
                    (By.CSS_SELECTOR, "input[name='btnK']"),
                    (By.CSS_SELECTOR, "button[type='submit']"),
                    (By.CSS_SELECTOR, "[aria-label*='Search']"),
                    (By.XPATH, "//input[@value='Google Search']")
                ]
                
                search_button = None
                for btn_type, btn_value in search_buttons:
                    try:
                        search_button = driver.find_element(btn_type, btn_value)
                        if search_button.is_displayed():
                            search_button.click()
                            print(f"[{browser}] Search submitted using button: {btn_type}={btn_value}")
                            break
                    except Exception:
                        continue
                        
                if not search_button:
                    raise Exception("Could not submit search")

        # --- Assert results page (with flexible matching) ---
        try:
            # Wait for navigation to complete
            wait.until(lambda d: "search" in d.current_url.lower() or SEARCH_TERM.lower() in d.title.lower())
        except Exception:
            # If URL/title doesn't change, check if results appeared on same page
            try:
                wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, "#search, .g, [data-ved]")))
                print(f"[{browser}] Search results appeared on same page")
            except Exception:
                raise Exception("Search results did not load within timeout")
        
        print(f"[{browser}] Search completed. Current URL: {driver.current_url[:80]}...")
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
