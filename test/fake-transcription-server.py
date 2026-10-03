#!/usr/bin/env python3
"""A stand-in for an OpenAI-shaped transcription endpoint.

Lets the api backend be tested without a network, an account, or sending
anyone's audio anywhere. It records what it received so the tests can assert on
the Authorization header and the form fields, which is the only way to prove
the API key is sent correctly AND kept out of argv and the log.

  fake-transcription-server.py PORT RECORD_FILE [--require-auth] [--status N]
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
RECORD = sys.argv[2]
REQUIRE_AUTH = "--require-auth" in sys.argv
FORCE_STATUS = 0
if "--status" in sys.argv:
    FORCE_STATUS = int(sys.argv[sys.argv.index("--status") + 1])

TRANSCRIPT = "the fake endpoint replied"


def form_fields(body: bytes) -> dict:
    """Pull simple form values out of a multipart body.

    Deliberately crude: a test fixture only needs the short text fields, and
    parsing them with a regex avoids depending on cgi, which is gone in 3.13.
    """
    out = {}
    for m in re.finditer(
        rb'name="([^"]+)"(?:; filename="([^"]*)")?\r\n(?:Content-Type: [^\r\n]+\r\n)?\r\n(.*?)\r\n--',
        body,
        re.S,
    ):
        name = m.group(1).decode()
        if m.group(2) is not None:          # a file part: record its name only
            out[name] = {"filename": m.group(2).decode(), "bytes": len(m.group(3))}
        else:
            out[name] = m.group(3).decode(errors="replace")
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass                                 # keep the test output readable

    def _reply(self, code, body, ctype="text/plain"):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        auth = self.headers.get("Authorization", "")

        record = {
            "path": self.path,
            "authorization": auth,
            "fields": form_fields(body),
        }
        with open(RECORD, "w") as fh:
            json.dump(record, fh, indent=2)

        if FORCE_STATUS:
            # Echo the Authorization header back in the error body. Real
            # endpoints do sometimes reflect the request, and it is the only
            # way to prove the client redacts a secret before logging a body
            # rather than just never having one to redact.
            self._reply(
                FORCE_STATUS,
                json.dumps({"error": {"message": "forced failure", "saw": auth}}),
                "application/json",
            )
            return
        if REQUIRE_AUTH and not auth.startswith("Bearer "):
            self._reply(401, '{"error":{"message":"missing api key"}}',
                        "application/json")
            return
        if record["fields"].get("response_format") == "text":
            self._reply(200, TRANSCRIPT)
        else:
            self._reply(200, json.dumps({"text": TRANSCRIPT}), "application/json")

    def do_GET(self):
        self._reply(200, "ok")               # reachability probe


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
