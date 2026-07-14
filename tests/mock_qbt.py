#!/usr/bin/env python3
import json
import sys
import time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, status=200, body=b"", content_type="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path == "/api/v2/auth/login":
            expected = b"username=TEST_QBT_USERNAME&password=TEST_QBT_PASSWORD"
            if body != expected:
                self.reply(403, b"Fails.")
                return
            self.send_response(200)
            self.send_header("Set-Cookie", "SID=test")
            self.end_headers()
            self.wfile.write(b"Ok.")
            return
        if self.path == "/api/v2/auth/logout":
            self.reply()
            return
        if self.path == "/api/v2/torrents/delete":
            if len(sys.argv) < 3:
                self.reply(500, b"delete recorder is required")
                return
            Path(sys.argv[2]).write_bytes(body)
            self.reply()
            return
        self.reply(404)

    def do_GET(self):
        if self.path != "/api/v2/torrents/info":
            self.reply(404)
            return
        now = int(time.time())
        torrent = {
            "hash": "mockhash",
            "name": "torrent de integracao",
            "category": "Categoria-Filmes",
            "progress": 1,
            "amount_left": 0,
            "completion_on": now - 10 * 86400,
            "last_activity": now - 8 * 86400,
            "size": 50 * 1073741824,
            "total_size": 50 * 1073741824,
            "num_complete": 20,
            "num_seeds": 1,
            "num_incomplete": 0,
            "num_leechs": 0,
            "uploaded": 0,
            "ratio": 2,
            "upspeed": 0,
            "dlspeed": 0,
            "state": "stalledUP",
            "force_start": False,
            "tags": "",
        }
        self.reply(200, json.dumps([torrent]).encode(), "application/json")


server = HTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
