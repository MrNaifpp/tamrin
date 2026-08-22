#!/usr/bin/env python3
"""Serves web/ with the single-page fallback Netlify's _redirects provides.

`python3 -m http.server` is enough to open the home screen, but /event/<id>
and /join/<code> — the links the app shares — are routes, not files, and it
answers them with a 404. This adds the one rule that makes local behaviour
match production.

    python3 scripts/serve-web.py [port]
"""

import http.server
import os
import socketserver
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "web")
ROOT = os.path.normpath(ROOT)
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8788


class SinglePageHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def translate_path(self, path):
        resolved = super().translate_path(path)
        # A path with no extension that matches no file is a route, not a
        # missing asset: hand it the shell and let the router read the URL.
        if not os.path.exists(resolved) and "." not in os.path.basename(resolved):
            return os.path.join(ROOT, "index.html")
        return resolved

    def end_headers(self):
        # Editing a screen and reloading should show the edit.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), SinglePageHandler) as httpd:
    print(f"تمرين على http://localhost:{PORT}  (وضع التجربة: ?demo=1)")
    httpd.serve_forever()
