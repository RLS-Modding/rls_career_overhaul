import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import requests


class BridgeHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/bridge":
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b"{}"

        try:
            data = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        url = data.get("url")
        method = data.get("method", "GET")
        headers = data.get("headers", {})
        req_body = data.get("body")

        if not url:
            self.send_response(400)
            self.end_headers()
            return

        try:
            r = requests.request(method, url, headers=headers, data=req_body, timeout=15)
            response = {
                "status": r.status_code,
                "text": r.text,
            }
            response_bytes = json.dumps(response).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response_bytes)))
            self.end_headers()
            self.wfile.write(response_bytes)
        except Exception:
            self.send_response(502)
            self.end_headers()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 8766), BridgeHandler)
    print("HTTP bridge running on http://127.0.0.1:8766/bridge")
    server.serve_forever()


if __name__ == "__main__":
    main()
