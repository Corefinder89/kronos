import os
import time
import unittest
import traceback

from selenium import webdriver
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.chrome.options import Options
from selenium.common.exceptions import WebDriverException


class HackerNewsSearchTest(unittest.TestCase):

    def setUp(self):
        try:
            chrome_options = Options()
            # chrome_options.add_argument("--headless")
            chrome_options.add_argument("--no-sandbox")
            chrome_options.add_argument('--disable-dev-shm-usage')
            caps = {'browserName': os.getenv('BROWSER', 'chrome')}
            address = os.getenv('NODE_HUB_ADDRESS')
            self.browser = webdriver.Remote(
                command_executor=f'http://{address}:4444/wd/hub',
                options=chrome_options,
                desired_capabilities=caps
            )
        except WebDriverException as e:
            traceback.print_exc()

    def test_hackernews_search_for_testdrivenio(self):
        browser = self.browser
        browser.get('https://news.ycombinator.com')
        search_box = browser.find_element_by_name('q')
        search_box.send_keys('testdriven.io')
        search_box.send_keys(Keys.RETURN)
        time.sleep(3)  # simulate long running test
        self.assertIn('testdriven.io', browser.page_source)

    def test_hackernews_search_for_selenium(self):
        browser = self.browser
        browser.get('https://news.ycombinator.com')
        search_box = browser.find_element_by_name('q')
        search_box.send_keys('selenium')
        search_box.send_keys(Keys.RETURN)
        time.sleep(3)  # simulate long running test
        self.assertIn('selenium', browser.page_source)

    def test_hackernews_search_for_testdriven(self):
        browser = self.browser
        browser.get('https://news.ycombinator.com')
        search_box = browser.find_element_by_name('q')
        search_box.send_keys('testdriven')
        search_box.send_keys(Keys.RETURN)
        time.sleep(3)  # simulate long running test
        self.assertIn('testdriven', browser.page_source)

    def test_hackernews_search_with_no_results(self):
        browser = self.browser
        browser.get('https://news.ycombinator.com')
        search_box = browser.find_element_by_name('q')
        search_box.send_keys('?*^^%')
        search_box.send_keys(Keys.RETURN)
        time.sleep(3)  # simulate long running test
        self.assertNotIn('<em>', browser.page_source)

    def tearDown(self):
        self.browser.quit()  # quit vs close?


if __name__ == '__main__':
    unittest.main(warnings='ignore')