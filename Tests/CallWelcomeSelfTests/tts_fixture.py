"""Local contract fixture: no real keys, network service, or speaker playback."""
import io
import json
import math
from pathlib import Path
import struct
import sys
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

audio = io.BytesIO()
with wave.open(audio, "wb") as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(24000)
    out.writeframes(b"".join(struct.pack("<h", int(12000 * math.sin(i * math.pi / 12))) for i in range(24000)))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        code, payload = 200, audio.getvalue()
        if self.path != "/v1/audio/speech" or body.get("response_format") != "wav" or body.get("stream") is not False:
            code, payload = 400, b"incorrect request contract"
        elif self.headers.get("X-API-Key") != "tts-test-key":
            code, payload = 401, b"secret-must-not-be-displayed"
        elif body.get("input") == "bad-audio":
            payload = b'{"error":"secret-must-not-be-displayed"}'
        elif body.get("input") == "redirect":
            code, payload = 302, b""
        elif body.get("input") == "slow":
            time.sleep(2)
        self.send_response(code)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(payload)))
        if code == 302:
            self.send_header("Location", "/redirect-target")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
