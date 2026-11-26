#!/usr/bin/env python3
"""Record the simulation page with Playwright (headless Chromium) until sim-live.json says `finished`.

  python3 record_video.py --url http://127.0.0.1:8600/index.html --live LIVE_JSON --out-dir VIDEO_DIR --real-addr 0x.. [--real-addr ..]
First the page looks up real mainnet wallets (typed into the lookup box), then it shows the live panel until the run is finished.
"""
import argparse, json, time
from pathlib import Path
from playwright.sync_api import sync_playwright


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--live", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--name", default="por-simulation")
    ap.add_argument("--real-addr", action="append", default=[])
    ap.add_argument("--tail", type=float, default=10.0, help="seconds to keep recording after the run finished")
    ap.add_argument("--max-seconds", type=float, default=3600)
    a = ap.parse_args()
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    live = Path(a.live)
    t0 = time.time()
    with sync_playwright() as p:
        browser = p.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1400, "height": 1000}, record_video_dir=str(out), record_video_size={"width": 1400, "height": 1000})
        page = ctx.new_page()
        video_start = time.time()  # wall clock of the first frame (used to cut the video by on-chain times)
        page.goto(a.url)
        page.wait_for_timeout(2500)
        for addr in a.real_addr:  # real mainnet wallets: type the address, look it up
            page.fill("#addr", "")
            page.type("#addr", addr, delay=25)
            page.click("#go")
            page.wait_for_timeout(5000)
        page.evaluate("document.getElementById('live').scrollIntoView()")
        done_at = None
        while time.time() - t0 < a.max_seconds:
            try:
                fin = json.loads(live.read_text()).get("finished")
            except (OSError, ValueError):
                fin = False
            if fin and done_at is None:
                done_at = time.time()
            if done_at and time.time() - done_at > a.tail:
                break
            page.wait_for_timeout(1000)
        page.screenshot(path=str(out / f"{a.name}-last.png"))
        video = page.video
        ctx.close()
        path = Path(video.path())
        target = out / f"{a.name}.webm"
        path.replace(target)
        browser.close()
    (out / f"{a.name}.json").write_text(json.dumps({"video_start_epoch": video_start, "video_end_epoch": time.time()}))
    print(json.dumps({"video": str(target), "seconds": round(time.time() - t0, 1)}))


if __name__ == "__main__":
    main()
