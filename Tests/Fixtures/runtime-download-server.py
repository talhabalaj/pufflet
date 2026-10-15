"""Loopback-only deterministic range/resume fixture; never used by app downloads."""
import http.server
import json
from pathlib import Path
import socket
import sys
import time

root = Path(sys.argv[1])
source = root / 'payload.bin'

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        with (root / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': self.path, 'range': self.headers.get('Range'),
                                  'ifRange': self.headers.get('If-Range')}) + '\n')
        if self.path == '/artifact':
            token = 'two' if (root / 'expire').exists() else 'one'
            self.send_response(302)
            self.send_header('Location', '/asset?token=' + token)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if not self.path.startswith('/asset?token='):
            self.send_error(404)
            return
        if (root / 'expire').exists() and self.path.endswith('one'):
            self.send_response(403)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        size = source.stat().st_size
        offset = 0
        byte_range = self.headers.get('Range')
        if byte_range:
            offset = int(byte_range.removeprefix('bytes=').split('-')[0])
        self.send_response(206 if byte_range else 200)
        self.send_header('Content-Length', str(size - offset))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('ETag', '"pufflet-fixture-v1"')
        self.send_header('Last-Modified', 'Wed, 14 Oct 2026 00:00:00 GMT')
        self.send_header('Content-Type', 'application/octet-stream')
        if byte_range:
            self.send_header('Content-Range', f'bytes {offset}-{size-1}/{size}')
        self.end_headers()
        disconnect = (root / 'disconnect').exists() and not byte_range
        try:
            with source.open('rb') as stream:
                stream.seek(offset)
                sent = 0
                while chunk := stream.read(32768):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    sent += len(chunk)
                    if disconnect and sent >= 1048576:
                        (root / 'disconnect').unlink(missing_ok=True)
                        self.connection.shutdown(socket.SHUT_RDWR)
                        self.connection.close()
                        return
                    time.sleep(0.004)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'ready.json').write_text(json.dumps({'port': server.server_port}))
server.serve_forever()
