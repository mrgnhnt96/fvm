#!/usr/bin/env python3
"""Verify the installer copy button against the browser's actual clipboard.

Usage: python3 tool/verify_clipboard_in_browser.py --origin http://fvm.mrgnhnt.com
An HTTP production URL must redirect to HTTPS before copying can work. Local
preview servers on localhost are secure contexts and can be tested as well.
Requires Chrome and websocket-client, like verify_search_in_browser.py.
"""

import argparse
import json
import shutil
import socket
import subprocess
import tempfile
import urllib.request
from urllib.parse import urlsplit

from verify_search_in_browser import Chrome, find_chrome, wait_for

INSTALL_SCRIPT = 'curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | sh'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--origin', default='http://fvm.mrgnhnt.com')
    parser.add_argument('--chrome')
    args = parser.parse_args()
    origin_url = urlsplit(args.origin)
    if origin_url.scheme == 'http' and origin_url.hostname not in {'localhost', '127.0.0.1', '::1'}:
        # Check the server separately: Chrome may upgrade HTTP on its own,
        # hiding a missing redirect that affects other browsers.
        with urllib.request.urlopen(args.origin.rstrip('/') + '/getting-started/installation/', timeout=30) as response:
            resolved = response.geturl()
        print(f'HTTP resolves to {resolved}', flush=True)
        assert urlsplit(resolved).scheme == 'https', 'Production HTTP must redirect to HTTPS so clipboard access is available'
    chrome_path = find_chrome(args.chrome)
    if chrome_path is None:
        raise SystemExit('Chrome not found; pass --chrome PATH.')
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    profile = tempfile.mkdtemp(prefix='fvm-clipboard-')
    process = subprocess.Popen([
        chrome_path, '--headless=new', f'--remote-debugging-port={port}',
        '--remote-allow-origins=*', f'--user-data-dir={profile}',
        '--no-first-run', '--disable-gpu', 'about:blank',
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    browser = None
    try:
        def targets():
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/json/list', timeout=2) as response:
                    return json.load(response)
            except (OSError, ValueError):
                return []
        assert wait_for(lambda: any(t.get('type') == 'page' for t in targets()), timeout=25), 'Chrome did not start'
        target = next(t for t in targets() if t.get('type') == 'page')
        browser = Chrome(target['webSocketDebuggerUrl'])
        browser.send('Page.enable')
        browser.send('Runtime.enable')
        browser.send('Page.navigate', url=args.origin.rstrip('/') + '/getting-started/installation/')
        assert wait_for(lambda: browser.eval("!!document.querySelector('.code-block button')"), timeout=30), 'No code copy button'
        context = browser.eval("({url: location.href, secure: isSecureContext, clipboard: !!navigator.clipboard})")
        print(json.dumps(context), flush=True)
        assert context['secure'] and context['clipboard'], 'Copy is unavailable: installation page is not a secure context'
        url = urlsplit(context['url'])
        origin = f'{url.scheme}://{url.netloc}'
        browser.send('Browser.grantPermissions', origin=origin, permissions=['clipboardReadWrite', 'clipboardSanitizedWrite'])
        browser.send('Page.bringToFront')
        # A sentinel prevents a stale clipboard value from making this pass.
        written = browser.send('Runtime.evaluate', expression="navigator.clipboard.writeText('fvm-copy-test-sentinel')",
                               awaitPromise=True, userGesture=True)
        assert 'exceptionDetails' not in written, written
        source = browser.eval("""(() => {
          const block = [...document.querySelectorAll('.code-block')].find(b => b.querySelector('pre code')?.textContent.includes('curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | sh'));
          if (!block) return null;
          block.querySelector('button').scrollIntoView({block: 'center'});
          const rect = block.querySelector('button').getBoundingClientRect();
          return {text: block.querySelector('pre code').textContent, x: rect.x + rect.width / 2, y: rect.y + rect.height / 2};
        })()""")
        assert source and source['text'].strip() == INSTALL_SCRIPT, 'Installer code block is missing or contains extra commands'
        def click_and_check():
            for kind in ['mouseMoved', 'mousePressed', 'mouseReleased']:
                browser.send('Input.dispatchMouseEvent', type=kind, x=source['x'], y=source['y'],
                             button='left', clickCount=1)
            return browser.eval('navigator.clipboard.readText()') == source['text']
        assert wait_for(click_and_check, timeout=15, interval=1), 'Copy button did not put the complete installer command on the clipboard'
        print('PASS: installer copy button writes the exact command to the clipboard')
        return 0
    finally:
        if browser:
            browser.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == '__main__':
    raise SystemExit(main())
