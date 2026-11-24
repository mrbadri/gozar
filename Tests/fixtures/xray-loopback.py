#!/usr/bin/python3
"""Generate a loopback VLESS server and serve the exit-test TLS download."""

import json
import re
import ssl
import subprocess
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def loopback_outbound(tag, port):
    return {"tag": tag, "protocol": "freedom", "settings": {
        "redirect": f"127.0.0.1:{port}",
        # VLESS blocks private final destinations by default in the pinned release.
        "finalRules": [{"action": "allow", "ip": ["127.0.0.1"], "port": str(port)}],
    }}


def configure(xray, directory, mode):
    decryption = encryption = "none"
    if mode == "encrypted":
        keys = subprocess.check_output([xray, "vlessenc"], text=True)
        # The last pair uses ML-KEM-768 authentication. Match the panel's random mode.
        decryption = re.findall(r'"decryption":\s*"([^"]+)"', keys)[-1].replace(".native.", ".random.", 1)
        encryption = re.findall(r'"encryption":\s*"([^"]+)"', keys)[-1].replace(".native.", ".random.", 1)
        assert decryption.startswith("mlkem768x25519plus.random.") and encryption.startswith("mlkem768x25519plus.random.")
    user = str(uuid.uuid4())
    (directory / "vless.link").write_text(
        f"vless://{user}@127.0.0.1:18443?encryption={encryption}&security=none&type=tcp#Loopback-{mode}\n"
    )
    (directory / "xray-server.json").write_text(json.dumps({
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "port": 18443, "listen": "127.0.0.1", "protocol": "vless",
            "settings": {"decryption": decryption, "clients": [{"id": user}]},
        }],
        "outbounds": [
            {"protocol": "blackhole"},
            loopback_outbound("http", 18088),
            loopback_outbound("tls", 18444),
        ],
        "routing": {"rules": [
            {"type": "field", "domain": ["full:xray-loopback.test"], "outboundTag": "http"},
            {"type": "field", "domain": ["full:speed.cloudflare.com"], "outboundTag": "tls"},
            {"type": "field", "ip": ["1.1.1.1"], "outboundTag": "tls"},
        ]},
    }))


class Download(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/__down?bytes=2000000":
            self.send_error(404)
            return
        data = b"x" * 2_000_000
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def serve(directory):
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(str(directory / "cert.pem"), str(directory / "key.pem"))
    with ThreadingHTTPServer(("127.0.0.1", 18444), Download) as server:
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        print("TLS ready on 18444", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        serve(Path(sys.argv[2]))
    else:
        configure(sys.argv[2], Path(sys.argv[3]), sys.argv[1])
