#!/usr/bin/env python3
"""Screenshot of CouchDB Fauxton (couchdb0, peer0.org1) with document PO-0001 of paymentchannel_payment.
Credentials are read from the test-network compose file and typed into the login form; they are never
printed and the password field is not visible in the captured document view."""
import os
import re
import sys

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
compose = open(os.path.join(ROOT, "fabric-samples/test-network/compose/compose-couch.yaml"), encoding="utf-8").read()
user = re.search(r"COUCHDB_USER=(\S+)", compose).group(1).strip('"')
pw = re.search(r"COUCHDB_PASSWORD=(\S+)", compose).group(1).strip('"')
out = sys.argv[1]
doc = sys.argv[2] if len(sys.argv) > 2 else "PO-0001"
db = sys.argv[3] if len(sys.argv) > 3 else "paymentchannel_payment"
port = sys.argv[4] if len(sys.argv) > 4 else "5984"  # 5984 = couchdb0 (peer0.org1), 7984 = couchdb1 (peer0.org2)
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1400, "height": 900}, device_scale_factor=1.25)
    pg.goto(f"http://localhost:{port}/_utils/#login")
    pg.wait_for_selector("#username", timeout=30000)
    pg.fill("#username", user)
    pg.fill("#password", pw)
    pg.keyboard.press("Enter")
    pg.wait_for_timeout(2500)
    pg.goto(f"http://localhost:{port}/_utils/#database/{db}/{doc}" if doc else f"http://localhost:{port}/_utils/#/{db}")
    pg.wait_for_timeout(3500)
    pg.screenshot(path=out)
    b.close()
print("saved", out)
