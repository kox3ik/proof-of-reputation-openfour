#!/usr/bin/env python3
"""Short clip of the page's wallet lookup (real mainnet wallets, then a fresh wallet), recorded with Playwright.

  python3 record_lookup.py --url http://127.0.0.1:8601/index.html --out CLIP.webm --addr 0x.. [--addr ..] [--seconds-each 6]
"""
import argparse, time
from pathlib import Path
from playwright.sync_api import sync_playwright


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--addr", action="append", required=True)
    ap.add_argument("--seconds-each", type=float, default=6.0)
    a = ap.parse_args()
    out = Path(a.out)
    tmp = out.parent / (out.stem + "-tmp")
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(viewport={"width": 1400, "height": 1000}, record_video_dir=str(tmp), record_video_size={"width": 1400, "height": 1000})
        page = ctx.new_page()
        page.goto(a.url)
        page.wait_for_timeout(1500)
        page.evaluate("document.getElementById('live').hidden = true; document.getElementById('lookup').scrollIntoView()")
        for addr in a.addr:
            page.fill("#addr", "")
            page.type("#addr", addr, delay=30)
            page.click("#go")
            page.wait_for_timeout(int(a.seconds_each * 1000))
        v = page.video
        ctx.close()
        Path(v.path()).replace(out)
        b.close()
    print(f"clip: {out}")


if __name__ == "__main__":
    main()
