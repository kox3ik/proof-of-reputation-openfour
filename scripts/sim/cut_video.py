#!/usr/bin/env python3
"""Cut the short submission video out of the long raw recording (no ffmpeg concat / drawtext needed).

Route: segments of the raw webm -> PNG frames (Playwright's ffmpeg) -> a small local HTML player that shows the frames at the chosen
speed with a caption bar -> Playwright records that player.  Segment times come from the run log (step times) and the recorder's sidecar.

  python3 cut_video.py --raw RAW.webm --sidecar RAW.json --runlog RUNLOG.json --work DIR --out CUT.webm [--stills PREFIX]
"""
import argparse, json, shutil, subprocess, threading, time, http.server, socketserver, functools
from datetime import datetime
from pathlib import Path
from playwright.sync_api import sync_playwright

FFMPEG = str(Path.home() / ".cache/ms-playwright/ffmpeg-1011/ffmpeg-linux")
FPS = 10  # player frame rate


def short(h):
    return f"{h[:8]}…{h[-6:]}" if h else ""


def plan(log, off):
    """Segments: (raw start, raw end, speed, caption, hold seconds at the end). Raw times are seconds in the raw video."""
    st = {s["name"]: s["t"] for s in log["steps"]}
    tx = {}
    for t in log["trades"]:
        tx.setdefault(t["label"].split(" ")[0] + ":" + t["side"], t["hash"])
    first_buy = next(t["hash"] for t in log["trades"] if t["label"].startswith("honestA first buy"))
    dump = next(t["hash"] for t in log["trades"] if "dumps T1" in t["label"])
    flagtx = next((e["hash"] for e in log["livePublishing"]["txList"] if e.get("flagged")), "")
    after = next((t["hash"] for t in log["trades"] if "AFTER the flag" in t["label"] and t["side"] == "buy"), "")
    forf = next((c["hash"] for c in log["claims"] if c["event"] == "Forfeited"), "")
    claim = next((c["hash"] for c in log["claims"] if c["event"] == "Claimed"), "")
    fl = log["flag"]
    r = lambda t: off + t + 4.0  # noqa: E731  (+4 s: the page polls the chain, so it shows an event a moment after the script saw it)
    return [
        (0, 24, 1, "Real mainnet wallets, looked up on the page: score 0–1, fee and deposit (largest, medium, one with a rug history)", 0, "lookup"),
        (24, 31, 1, "A wallet nobody knows yet pays a refundable deposit: 690 bps = 50 fee + 640 deposit", 0, "lookup"),
        (r(st["tokens created"]), r(st["fresh wallets bought"]) + 8, 4, f"New wallets pay a refundable deposit: 690 bps = 50 fee + 640 deposit   [{short(first_buy)}]", 0),
        (r(st["honestA scored"]) - 12, r(st["honest rounds"]) + 6, 8, "An honest wallet trades: its score rises after each publication, its fee drops to 50 bps, the deposit is gone", 0),
        (r(st["bundle bought"]) - 22, r(st["bundle bought"]) + 6, 5, "Four wallets buy the same token together", 0),
        (r(st["bundle bought"]) + 6, r(st["bundle dumped"]) - 7, 25, "...and wait", 0),
        (r(st["bundle dumped"]) - 7, r(st["bundle dumped"]) + 3, 1, f"They dump everything in the same block   [{short(dump)}]", 0),
        (r(st["bundle dumped"]) + 3, r(st["bundle flagged on chain"]) + 8, 1,
         f"The publisher flags all four: {fl['blocksAfterDump']} blocks / {fl['secondsAfterDump']} s after the dump   [{short(flagtx)}]", 0),
        (r(st["post-flag trades"]) - 6, r(st["post-flag trades"]) + 2, 2, f"The same bundle wallet buys and sells again, after the flag   [{short(after)}]", 0),
        (r(st["post-flag trades"]) + 2, r(st["post-flag trades"]) + 3, 1, "Same wallet, before vs after the flag: 50 → 690 bps on buy and sell (penalty 640)", 5),
        (r(st["bundle forfeited"]) - 14, r(st["bundle forfeited"]) + 4, 3, f"Bundle deposits and cashback are forfeited into the scam fund   [{short(forf)}]", 0),
        (r(st["honest claims done"]) - 14, r(st["honest claims done"]) + 6, 2, f"Honest wallets claim deposit + cashback + bonus from the fund   [{short(claim)}]", 0),
    ]


def extract(raw, lookup, work, segs):
    frames = []
    shutil.rmtree(work / "frames", ignore_errors=True)
    (work / "frames").mkdir(parents=True)
    for i, seg in enumerate(segs):
        a, b, speed, cap, hold = seg[:5]
        src = lookup if (len(seg) > 5 and seg[5] == "lookup") else raw
        a = max(a, 0)
        subprocess.run([FFMPEG, "-v", "error", "-ss", f"{a:.2f}", "-t", f"{max(b - a, 0.2):.2f}", "-i", str(src), "-r", f"{FPS / speed:.4f}", "-c:v", "png", "-f", "image2",
                        str(work / "frames" / f"s{i:02d}_%04d.png")], check=True)
        files = sorted((work / "frames").glob(f"s{i:02d}_*.png"))
        for k, f in enumerate(files):
            frames.append({"src": f"frames/{f.name}", "cap": cap, "speed": speed, "n": 1 + (round(hold * FPS) if (hold and k == len(files) - 1) else 0)})
    return frames


PLAYER = """<!doctype html><meta charset=utf-8><title>cut</title>
<style>html,body{margin:0;background:#000;overflow:hidden;font-family:system-ui,sans-serif}#f{width:1400px;height:1000px;display:block}
#bar{position:fixed;left:0;right:0;bottom:0;background:rgba(10,24,20,.93);color:#fff;font-size:27px;line-height:1.3;padding:16px 28px;min-height:62px}
#mark{position:fixed;right:18px;top:14px;background:rgba(10,24,20,.9);color:#ffd36b;font-size:19px;padding:6px 14px;border-radius:999px}
#card{position:fixed;inset:0;background:#10241d;color:#fff;display:none;padding:110px 120px;font-size:34px;line-height:1.5}#card h1{font-size:52px;margin:0 0 30px}</style>
<img id=f><div id=mark></div><div id=bar></div><div id=card></div>
<script>
const FPS=%(fps)d, frames=%(frames)s, closing=%(closing)s;
const img=document.getElementById('f'),bar=document.getElementById('bar'),mark=document.getElementById('mark'),card=document.getElementById('card');
const pre=[];function warm(i){for(let k=i;k<Math.min(i+40,frames.length);k++)if(!pre[k]){pre[k]=new Image();pre[k].src=frames[k].src;}}
let i=0,rep=0;
function show(){
  if(i>=frames.length){img.style.display='none';bar.style.display='none';mark.style.display='none';card.style.display='block';
    card.innerHTML='<h1>'+closing.title+'</h1>'+closing.lines.map(x=>'<div>'+x+'</div>').join('');setTimeout(()=>{window.done=true},closing.seconds*1000);return;}
  const f=frames[i];warm(i);img.src=f.src;bar.textContent=f.cap;
  mark.textContent='BSC testnet'+(f.speed>1?' · sped up ×'+f.speed:'');
  if(++rep>=f.n){rep=0;i++;}
  setTimeout(show,1000/FPS);
}
show();
</script>"""


def main():
    ap = argparse.ArgumentParser()
    for k in ("raw", "sidecar", "runlog", "work", "out"):
        ap.add_argument("--" + k, required=True)
    ap.add_argument("--stills", default=None)
    ap.add_argument("--lookup", required=True, help="clip of the page lookup (record_lookup.py)")
    a = ap.parse_args()
    work = Path(a.work)
    work.mkdir(parents=True, exist_ok=True)
    log = json.loads(Path(a.runlog).read_text())
    side = json.loads(Path(a.sidecar).read_text())
    off = datetime.fromisoformat(log["startedAt"].replace("Z", "+00:00")).timestamp() - side["video_start_epoch"]
    segs = plan(log, off)
    frames = extract(Path(a.raw), Path(a.lookup), work, segs)
    total = sum(f["n"] for f in frames) / FPS + 9
    closing = {"title": "Proof of Reputation, live on BSC testnet", "seconds": 8, "lines": [
        "Shown: ratings from real mainnet history, a deposit for newcomers, a live score,",
        "a bundle rug flagged within seconds, a penalty and forfeited deposits for the bundle,",
        "and refund + cashback + bonus for honest wallets.", "",
        "Every transaction is on BSC testnet: see the run log."]}
    (work / "player.html").write_text(PLAYER % {"fps": FPS, "frames": json.dumps(frames), "closing": json.dumps(closing)})
    print(f"{len(frames)} frames, planned length about {total:.0f} s")
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(work))
    handler.log_message = lambda *x: None
    srv = socketserver.TCPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_address[1]}/player.html"
    vdir = work / "rec"
    shutil.rmtree(vdir, ignore_errors=True)
    t0 = time.time()
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(viewport={"width": 1400, "height": 1000}, record_video_dir=str(vdir), record_video_size={"width": 1400, "height": 1000})
        page = ctx.new_page()
        page.goto(url)
        marks = [0.07, 0.25, 0.5, 0.68]  # stills at these shares of the planned length
        shots = [t * total for t in marks]
        k = 0
        while not page.evaluate("window.done === true") and time.time() - t0 < total + 60:
            if a.stills and k < len(shots) and time.time() - t0 >= shots[k]:
                page.screenshot(path=f"{a.stills}-{k + 1}.png")
                k += 1
            page.wait_for_timeout(300)
        video = page.video
        ctx.close()
        Path(video.path()).replace(a.out)
        b.close()
    srv.shutdown()
    print(json.dumps({"out": a.out, "seconds": round(time.time() - t0, 1)}))


if __name__ == "__main__":
    main()
