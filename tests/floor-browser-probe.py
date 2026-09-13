#!/usr/bin/env python3
"""Headless-browser probes for the Floor page (file:// desk, real layout).

The grep-level suite cannot see layout: whether an anchor target lands below
the sticky header, or which LED a failed replay fetch leaves on the page.
This probe loads the built site in headless Chrome through an exact-size
iframe (Chrome enforces a minimum window width, so the 400 px phone viewport
is framed), runs the checks inside the page, and prints one line per check:

    PASS <name>
    FAIL <name>

Exit 0 when every check passed, 1 on any failure, 77 when no headless
browser is available (the caller treats 77 as a skip).

Modes:
    anchors             click every visible strip figure and every in-page
                        NEEDS YOU action; assert each target's top lands at
                        or below the sticky header's bottom.
    replay-unavailable  open ?replay=1&dispatch_id=<id> on the static desk
                        (no /api); assert the failure is a visible state:
                        LED not live, watermark names the unavailable replay,
                        strip figures hidden, Exit to live Floor present.
"""

import argparse
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

CHROME_CANDIDATES = [
    os.environ.get("CHROME_BIN", ""),
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    shutil.which("google-chrome") or "",
    shutil.which("google-chrome-stable") or "",
    shutil.which("chromium") or "",
    shutil.which("chromium-browser") or "",
]

VIRTUAL_BUDGET_MS = 20000

ANCHORS_JS = r"""
var frame = document.getElementById("f");
frame.addEventListener("load", function () {
  var tries = 0;
  var iv = setInterval(function () {
    tries++;
    var w = frame.contentWindow, d = w && w.document;
    if (!d || !d.getElementById("floor-strip")) { if (tries > 100) { clearInterval(iv); log("FAIL anchors: page did not load"); } return; }
    var prop = w.getComputedStyle(d.documentElement).getPropertyValue("--floor-header-h").trim();
    if (!prop) { if (tries > 100) { clearInterval(iv); log("FAIL anchors: floor.js never set --floor-header-h"); } return; }
    clearInterval(iv);
    log("NOTE anchors: measured --floor-header-h " + prop);
    runAnchors(w, d);
  }, 100);
});
function runAnchors(w, d) {
  var header = d.querySelector("header.site");
  if (!header) { log("FAIL anchors: no header.site"); return; }
  var links = d.querySelectorAll('#floor-strip a.sfig[href^="#"], #floor-needs-list a.act[href^="#"]');
  var items = [];
  Array.prototype.forEach.call(links, function (a) {
    if (!a.hidden && a.offsetParent !== null) items.push(a);
  });
  if (!items.length) { log("FAIL anchors: no visible in-page anchors found"); return; }
  var i = 0;
  (function step() {
    if (i >= items.length) { log("PROBE DONE"); return; }
    var a = items[i++];
    var href = a.getAttribute("href");
    var t = d.getElementById(href.slice(1));
    if (!t) { log("FAIL anchors: no target " + href); return step(); }
    a.click();
    setTimeout(function () {
      var hb = header.getBoundingClientRect().bottom;
      var tt = t.getBoundingClientRect().top;
      log((tt >= hb - 1 ? "PASS" : "FAIL") + " anchors " + href +
          " top=" + Math.round(tt) + " headerBottom=" + Math.round(hb));
      step();
    }, 150);
  })();
}
"""

REPLAY_JS = r"""
var frame = document.getElementById("f");
frame.addEventListener("load", function () {
  var tries = 0;
  var iv = setInterval(function () {
    tries++;
    var w = frame.contentWindow, d = w && w.document;
    if (!d || !d.getElementById("floor-strip")) { if (tries > 100) { clearInterval(iv); log("FAIL replay-static: page did not load"); } return; }
    var wm = d.getElementById("floor-watermark");
    if (wm && !wm.hidden && wm.textContent) { clearInterval(iv); return settle(w, d); }
    if (tries > 100) { clearInterval(iv); log("FAIL replay-static: watermark never painted"); }
  }, 100);
});
function settle(w, d) {
  setTimeout(function () { checkReplay(w, d); }, 500);
}
function checkReplay(w, d) {
  var led = d.getElementById("floor-led");
  var ledCls = led ? led.className : "(missing)";
  log((led && ledCls !== "led live" ? "PASS" : "FAIL") +
      " replay-static: LED is not live after the failed replay fetch (class \"" + ledCls + "\")");
  var wm = d.getElementById("floor-watermark");
  var wmText = wm && !wm.hidden ? wm.textContent : "";
  log((/not available on this desk/.test(wmText) ? "PASS" : "FAIL") +
      " replay-static: watermark says the replay is not available on this desk");
  log((/Exit to live Floor/.test(wmText) && wm.querySelector("a.btn-replay") ? "PASS" : "FAIL") +
      " replay-static: Exit to live Floor action present");
  var figs = ["strip-running", "strip-queued", "strip-landed", "strip-failed", "strip-needs", "strip-event"];
  var shown = figs.filter(function (id) { var e = d.getElementById(id); return e && !e.hidden; });
  log((shown.length === 0 ? "PASS" : "FAIL") +
      " replay-static: strip figures hidden (visible: " + (shown.join(",") || "none") + ")");
  var seat = d.querySelector("[data-elapsed-from]");
  if (!seat) { log("NOTE replay-static: no elapsed span to watch"); log("PROBE DONE"); return; }
  var before = seat.textContent;
  setTimeout(function () {
    log((seat.textContent === before ? "PASS" : "FAIL") +
        " replay-static: elapsed does not tick on the frozen desk");
    log("PROBE DONE");
  }, 2500);
}
"""


def find_chrome():
    for c in CHROME_CANDIDATES:
        if c and os.path.exists(c):
            return c
    return None


def dump_dom(cmd, deadline_s=60):
    """Run headless Chrome; return the dumped DOM.

    Chrome writes the dump and then lingers (updater and crashpad keep the
    process alive on macOS), so read stdout until the closing </html> tag
    arrives, then stop waiting and kill the process.
    """
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True,
                            start_new_session=True)
    chunks = []

    def reader():
        while True:
            c = proc.stdout.read(1)
            if not c:
                break
            chunks.append(c)

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    deadline = time.time() + deadline_s
    dom = ""
    while time.time() < deadline:
        dom = "".join(chunks)
        if "</html>" in dom:
            break
        if proc.poll() is not None:
            time.sleep(0.2)
            dom = "".join(chunks)
            break
        time.sleep(0.1)
    try:
        proc.kill()
    except OSError:
        pass
    return dom


def run_probe(site, mode, width, height, query):
    chrome = find_chrome()
    if not chrome:
        print("SKIP no headless browser found")
        return 77
    target = (site / "live" / "index.html").as_uri() + query
    harness_js = ANCHORS_JS if mode == "anchors" else REPLAY_JS
    page = (
        "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\n"
        f"<iframe id=\"f\" src=\"{html.escape(target, quote=True)}\" "
        f"style=\"width:{width}px;height:{height}px;border:0\"></iframe>\n"
        "<pre id=\"probe-out\"></pre>\n"
        "<script>\n"
        "function log(s) {\n"
        "  var p = document.getElementById(\"probe-out\");\n"
        "  p.textContent += s + \"\\n\";\n"
        "}\n"
        + harness_js +
        "</script>\n</body></html>\n"
    )
    with tempfile.TemporaryDirectory(prefix="floor-probe-") as td:
        harness = Path(td) / "harness.html"
        harness.write_text(page)
        cmd = [
            chrome, "--headless=new", "--disable-gpu", "--no-first-run",
            "--no-default-browser-check", "--disable-extensions",
            f"--user-data-dir={td}/chrome-profile",
            "--allow-file-access-from-files",
            f"--virtual-time-budget={VIRTUAL_BUDGET_MS}",
            "--dump-dom", harness.as_uri(),
        ]
        dom = dump_dom(cmd)
        if "probe-out" not in dom:
            cmd[1] = "--headless"
            dom = dump_dom(cmd)
    m = re.search(r'<pre id="probe-out">(.*?)</pre>', dom, re.S)
    if not m:
        print("FAIL probe: no probe output in the dumped DOM")
        return 1
    text = html.unescape(m.group(1))
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if not any(ln.startswith(("PASS", "FAIL")) for ln in lines):
        print("FAIL probe: probe produced no verdicts")
        for ln in lines:
            print("  " + ln)
        return 1
    fails = 0
    for ln in lines:
        print(ln)
        if ln.startswith("FAIL"):
            fails += 1
    if not any(ln == "PROBE DONE" for ln in lines):
        print("FAIL probe: probe did not run to completion")
        fails += 1
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--site", required=True, help="built site dir containing live/index.html")
    ap.add_argument("--mode", choices=["anchors", "replay-unavailable"], required=True)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=800)
    ap.add_argument("--query", default="")
    args = ap.parse_args()
    site = Path(args.site).resolve()
    if not (site / "live" / "index.html").is_file():
        print(f"FAIL probe: {site}/live/index.html not found")
        return 1
    sys.exit(run_probe(site, args.mode, args.width, args.height, args.query))


if __name__ == "__main__":
    main()
