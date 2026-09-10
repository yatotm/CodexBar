#!/usr/bin/env python3
"""统计服务只开放固定的只读资源, 采集器与 HTTP 请求独立运行"""

import argparse
import hmac
import http.server
import json
import os
import pathlib
import signal
import socketserver
import sqlite3
import sys
import threading
import urllib.parse

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "CodexBar/Resources"))
from UsageCollector import Collector, Database, encode


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, address, directory, token, providers=("codex", "claude")):
        self.directory = directory
        self.token = token
        self.providers = providers
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(address, Handler)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        return connection, address

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        pass


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "CodexBarCollector/1"
    sys_version = ""

    def log_message(self, format, *args):
        pass

    def respond(self, status, value):
        body = encode(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        authorization = self.headers.get("Authorization", "")
        if not hmac.compare_digest(authorization.encode(), b"Bearer " + self.server.token):
            self.respond(401, {"error": "unauthorized"})
            return
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/healthz":
            self.respond(200, {"protocol": 1})
            return
        if parsed.path != "/v1/changes":
            self.respond(404, {"error": "not_found"})
            return
        try:
            query = urllib.parse.parse_qs(parsed.query, max_num_fields=3, keep_blank_values=True)
            if set(query) - {"cursor", "epoch", "limit"} or any(len(v) != 1 for v in query.values()):
                raise ValueError()
            cursor = int(query.get("cursor", ["0"])[0])
            limit = int(query.get("limit", ["1500"])[0])
            epoch = query.get("epoch", [""])[0]
            if not 0 <= cursor <= 2 ** 63 - 1 or not 1 <= limit <= 3000 or len(epoch) > 36:
                raise ValueError()
        except ValueError:
            self.respond(400, {"error": "invalid_query"})
            return
        try:
            database = Database(self.server.directory, writable=False)
            try:
                result = database.export(epoch, cursor, limit, self.server.providers)
            finally:
                database.connection.close()
            self.respond(200, result)
        except (OSError, ValueError, sqlite3.Error):
            self.respond(503, {"error": "temporarily_unavailable"})

    def do_POST(self):
        self.respond(405, {"error": "read_only"})


def run():
    parser = argparse.ArgumentParser(description="CodexBar 只读统计服务")
    parser.add_argument("--state-dir", type=pathlib.Path, default=pathlib.Path("/data"))
    parser.add_argument("--codex-home", type=pathlib.Path, default=pathlib.Path("/logs/codex"))
    parser.add_argument("--claude-home", type=pathlib.Path, default=pathlib.Path("/logs/claude"))
    parser.add_argument("--providers", choices=("codex", "claude", "codex,claude"), default="codex")
    parser.add_argument("--token-file", type=pathlib.Path, required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--interval", type=int, default=300)
    args = parser.parse_args()
    token = args.token_file.read_bytes().strip()
    if len(token) < 32 or len(token) > 512 or any(c <= 32 or c >= 127 for c in token):
        raise ValueError("服务令牌格式无效")
    if args.interval < 30 or not 1 <= args.port <= 65535:
        raise ValueError("服务参数无效")
    os.umask(0o077)
    Database(args.state_dir).connection.close()
    server = Server((args.listen, args.port), args.state_dir, token, args.providers.split(","))
    stopped = threading.Event()

    def collect():
        while not stopped.is_set():
            delay = args.interval
            try:
                database = Database(args.state_dir)
                try:
                    collector = Collector(database, args.codex_home, args.claude_home, args.providers.split(","), 10)
                    collector.collect()
                    if not collector.scan_complete:
                        delay = 2
                finally:
                    database.connection.close()
            except (OSError, ValueError, sqlite3.Error):
                print("统计采集暂时失败, 保留已有数据", file=sys.stderr)
            stopped.wait(delay)

    def stop(signum, frame):
        stopped.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    worker = threading.Thread(target=collect, daemon=True)
    worker.start()
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        stopped.set()
        server.server_close()
        worker.join(timeout=12)


if __name__ == "__main__":
    run()
