"""Deterministic local System One fixture for mixed-policy Coworld episodes."""

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    log_path: Path

    def do_POST(self) -> None:
        assert self.path == "/v1/systemone"
        request = json.loads(self.rfile.read(int(self.headers["content-length"])))
        criteria = request["questions"]["decision"]["criteria"]
        selected = next(name for name in criteria if name != "baseline")
        probabilities = {name: float(name == selected) for name in criteria}
        response = json.dumps(
            {
                "model": "local-systemone-fixture",
                "answers": {
                    "decision": {
                        "type": "choice",
                        "choice": selected,
                        "probabilities": probabilities,
                    }
                },
                "usage": {"input_tokens": 0, "output_tokens": 0},
            }
        ).encode()
        with self.log_path.open("a") as log:
            log.write(
                json.dumps({"selected": selected, "choices": len(criteria), "state": request["state"]})
                + "\n"
            )
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, format: str, *args: object) -> None:
        pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18998)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    Handler.log_path = args.log
    HTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
