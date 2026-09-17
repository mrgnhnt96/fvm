#!/usr/bin/env python3
"""Drives a real headless Chrome over the DevTools Protocol to check that the
docs site's search actually works — served at the domain root, the way it ships.

Two reasons this exists rather than more `dart test`.

DOM assertions are not enough. On the site this search component was extracted
from, every DOM check passed — dialog present, results present, correct hrefs —
while the panel rendered **two pixels tall**, because an ancestor
`backdrop-filter` on the header made it the containing block for
`position: fixed`. This site's header carries `backdrop-filter: blur(8px)` too,
so the hazard is live here; `SearchDialog` avoids it by calling `showModal()`
and living in the browser's top layer. That is a claim about rendering, and the
only way to check it is to measure the rendered box.

And the index fetch is the one reference on this site that appears in no HTML
attribute: it is issued from compiled JavaScript, so `build_smoke_test.dart`'s
sweep over every `href`/`src` walks straight past it. That test resolves the URL
by hand; this checks that a browser really asks for it and really gets an index
back.

The run starts on a NESTED page. `SearchDialog` takes a relative index path and
resolves it against `<base href>`, so one copy at the site root serves a reader
standing anywhere — and a nested route is where a path resolved against the page
instead of the base lands somewhere else, while the home page is where that same
mistake still works.

    dart run tool/build_search_index.dart
    dart run jaspr_cli:jaspr build
    python3 tool/verify_search_in_browser.py [--keep-screenshots DIR]

Exits non-zero on the first failed check. Needs `websocket-client` and a
Chrome; pass `--chrome` or set `CHROME` if it is not in the usual places.
"""

from __future__ import annotations

import argparse
import base64
import functools
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

import websocket  # websocket-client

HTTP_PORT = 8899
CDP_PORT = 9333
SITE = pathlib.Path(__file__).resolve().parent.parent / "build" / "jaspr"

# In preference order. Chrome for Testing is what playwright downloads, and on
# a machine with no Chrome installed it is usually the only one present.
CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    str(
        pathlib.Path.home()
        / "Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64"
        / "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
    ),
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
]

# Every request the page made whose URL mentions the index, so a failure says
# WHERE the browser looked instead of only that it looked somewhere wrong.
_SEARCH_INDEX_REQUESTS = (
    "performance.getEntriesByType('resource')"
    ".map(e => e.name).filter(n => n.includes('search-index'))"
)

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> bool:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}{'' if ok else f' — {detail}'}")
    if not ok:
        failures.append(label)
    return ok


class Chrome:
    """The few CDP calls this needs, over one WebSocket."""

    def __init__(self, ws_url: str) -> None:
        self._ws = websocket.create_connection(ws_url, timeout=20)
        self._id = 0

    def send(self, method: str, **params: object) -> dict:
        self._id += 1
        self._ws.send(json.dumps({"id": self._id, "method": method, "params": params}))
        while True:
            message = json.loads(self._ws.recv())
            if message.get("id") == self._id:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message.get("result", {})

    def eval(self, expression: str) -> object:
        result = self.send(
            "Runtime.evaluate",
            expression=expression,
            returnByValue=True,
            awaitPromise=True,
        )
        return result.get("result", {}).get("value")

    def key(self, key: str, code: str, vk: int, modifiers: int = 0) -> None:
        for kind in ("keyDown", "keyUp"):
            self.send(
                "Input.dispatchKeyEvent",
                type=kind,
                key=key,
                code=code,
                windowsVirtualKeyCode=vk,
                nativeVirtualKeyCode=vk,
                modifiers=modifiers,
            )

    def type_text(self, text: str) -> None:
        # `char` only. Sending keyDown *and* char types every character twice,
        # which is how you get "iinnssttaallll" in the search box.
        for character in text:
            self.send("Input.dispatchKeyEvent", type="char", text=character)
            time.sleep(0.02)

    def screenshot(self, path: pathlib.Path) -> None:
        data = self.send("Page.captureScreenshot", format="png")["data"]
        path.write_bytes(base64.b64decode(data))

    def close(self) -> None:
        self._ws.close()


def wait_for(predicate, timeout: float = 10.0, interval: float = 0.1) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def find_chrome(explicit: str | None) -> str | None:
    for candidate in [explicit, os.environ.get("CHROME"), *CHROME_CANDIDATES]:
        if candidate and pathlib.Path(candidate).exists():
            return candidate
    return None


def measure_panel(browser) -> float:
    """Rendered height of the search panel, in CSS pixels."""
    return browser.eval("document.querySelector('.jaspr-search-panel')?.getBoundingClientRect().height ?? 0") or 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep-screenshots", metavar="DIR")
    parser.add_argument("--chrome", metavar="PATH")
    args = parser.parse_args()

    if not (SITE / "index.html").exists():
        print(f"No built site at {SITE} — run: dart run jaspr_cli:jaspr build", file=sys.stderr)
        return 2
    base_href = (SITE / "index.html").read_text().split('<base href="', 1)[-1].split('"', 1)[0]
    if base_href != "/":
        print(
            f'{SITE}/index.html has <base href="{base_href}">, not "/". The site is '
            "published on its own subdomain and jaspr's static build emits the domain "
            "root; a different base means the build is not the artifact that ships.",
            file=sys.stderr,
        )
        return 2
    if not (SITE / "search-index.json").exists():
        print(
            f"No {SITE}/search-index.json — run: dart run tool/build_search_index.dart, "
            "then rebuild.",
            file=sys.stderr,
        )
        return 2

    chrome_path = find_chrome(args.chrome)
    if chrome_path is None:
        print("No Chrome found. Pass --chrome PATH or set CHROME.", file=sys.stderr)
        return 2

    shots = pathlib.Path(args.keep_screenshots) if args.keep_screenshots else pathlib.Path(tempfile.mkdtemp())
    shots.mkdir(parents=True, exist_ok=True)
    profile = tempfile.mkdtemp(prefix="cdp-fvm-")

    # Served at the domain root, exactly as GitHub Pages serves a site on its
    # own repo-level custom domain, and exactly as jaspr's static build emits
    # it. The build output is published byte for byte, so the thing under a
    # browser here is the thing readers get.
    web_root = str(SITE)

    # Started here, after the build: `jaspr build` deletes and recreates
    # build/jaspr, and a server started inside the old directory keeps serving
    # the deleted inode — stale pages and spurious 404s.
    server = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(HTTP_PORT), "--bind", "127.0.0.1"],
        cwd=web_root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    chrome = subprocess.Popen(
        [
            chrome_path,
            "--headless=new",
            f"--remote-debugging-port={CDP_PORT}",
            "--remote-allow-origins=*",  # without this the WS handshake 403s
            f"--user-data-dir={profile}",
            "--window-size=1440,900",
            "--no-first-run",
            "--disable-gpu",
            "about:blank",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    def cleanup() -> None:
        for process in (chrome, server):
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
        shutil.rmtree(profile, ignore_errors=True)

    origin = f"http://127.0.0.1:{HTTP_PORT}"

    try:
        fetch_targets = functools.partial(urllib.request.urlopen, f"http://127.0.0.1:{CDP_PORT}/json/list", timeout=2)

        def targets():
            try:
                return json.loads(fetch_targets().read())
            except (urllib.error.URLError, OSError, json.JSONDecodeError):
                return []

        if not wait_for(lambda: any(t.get("type") == "page" for t in targets()), timeout=25):
            print("Chrome never exposed a page target", file=sys.stderr)
            return 2

        page = next(t for t in targets() if t.get("type") == "page")
        browser = Chrome(page["webSocketDebuggerUrl"])
        browser.send("Page.enable")
        browser.send("Runtime.enable")
        # `--window-size` does not set the layout viewport under
        # `--headless=new`; without this the page renders ~800px wide, where
        # DocsLayout collapses the sidebar behind the hamburger and the search
        # trigger loses its label — a mobile layout masquerading as a desktop
        # screenshot.
        browser.send(
            "Emulation.setDeviceMetricsOverride",
            width=1440,
            height=900,
            deviceScaleFactor=1,
            mobile=False,
        )

        # A nested route, not the home page: this is where a relative index
        # path resolved against the page rather than against `<base href>`
        # would ask for /commands/search-index.json and get a 404.
        start = f"{origin}/commands/"
        print(f"nested page at {start}")
        browser.send("Page.navigate", url=start)
        hydrated = wait_for(
            lambda: browser.eval("!!document.querySelector('.jaspr-search-trigger')") is True, timeout=20
        )
        check("the search trigger renders", hydrated)
        browser.screenshot(shots / "01-index.png")

        print("⌘K search")
        browser.key("k", "KeyK", 75, modifiers=4)  # 4 = Meta
        opened = wait_for(lambda: browser.eval("!!document.getElementById('jaspr-search-dialog')") is True, timeout=5)
        check("⌘K opens the dialog", opened)

        if opened:
            check(
                "the dialog is in the top layer, not clipped by the header's backdrop-filter",
                browser.eval("document.getElementById('jaspr-search-dialog').matches(':modal')") is True,
            )
            # The two-pixel bug: every DOM assertion passed while this was 2.
            # Measured empty, before typing — an empty panel is legitimately
            # short, so the threshold only has to be far above a collapsed box,
            # and the real evidence is that it grows once results render.
            empty_height = measure_panel(browser)
            check("the search panel is not clipped to nothing", empty_height > 100, f"height was {empty_height}px")

            browser.type_text("resolution order")
            got_results = wait_for(
                lambda: (browser.eval("document.querySelectorAll('.jaspr-search-hit').length") or 0) > 0,
                timeout=10,
            )
            check("typing produces results", got_results)
            check(
                "the index was fetched from the site root, not from beside the nested page",
                browser.eval(
                    "performance.getEntriesByType('resource')"
                    f".some(e => e.name === '{origin}/search-index.json')"
                )
                is True,
                f"fetched instead: {browser.eval(_SEARCH_INDEX_REQUESTS)!r}",
            )
            check(
                "matches are highlighted",
                (browser.eval("document.querySelectorAll('.jaspr-search-hit mark').length") or 0) > 0,
            )
            first_href = browser.eval("document.querySelector('.jaspr-search-hit')?.getAttribute('href')")
            check(
                "the top result links at the resolution order page",
                isinstance(first_href, str) and "/versions" in first_href,
                f"href was {first_href!r}",
            )
            results_height = measure_panel(browser)
            check(
                "the panel grows to hold the results",
                results_height > empty_height + 150,
                f"empty {empty_height}px -> results {results_height}px",
            )
            check(
                "every result row has a real height",
                browser.eval(
                    "[...document.querySelectorAll('.jaspr-search-hit')]"
                    ".every(e => e.getBoundingClientRect().height > 20)"
                )
                is True,
            )
            browser.screenshot(shots / "02-search-results.png")

            browser.key("ArrowDown", "ArrowDown", 40)
            check(
                "arrow keys move the selection",
                (browser.eval("document.querySelectorAll('.jaspr-search-hit[data-selected]').length") or 0) == 1,
            )

            # The payoff: following a result has to land on a real page. A
            # result href built relative to the page the reader was standing on
            # would aim at /commands/versions, which is
            # a 404 here and nowhere else.
            browser.key("Enter", "Enter", 13)
            landed = wait_for(
                lambda: isinstance(browser.eval("location.pathname"), str)
                # startswith, not `in`: the failure this catches is landing on
                # /commands/versions, which contains
                # the route it was supposed to reach.
                and browser.eval("location.pathname").startswith("/versions"),
                timeout=10,
            )
            check("Enter navigates to the result", landed, f"landed on {browser.eval('location.pathname')!r}")
            check(
                "the page it landed on really rendered",
                wait_for(lambda: browser.eval("!!document.querySelector('.docs')") is True, timeout=15),
            )
            browser.screenshot(shots / "03-followed-result.png")

        browser.close()
    finally:
        cleanup()

    print(f"\nscreenshots: {shots}")
    if failures:
        print(f"{len(failures)} check(s) failed: {', '.join(failures)}", file=sys.stderr)
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
