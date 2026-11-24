#!/usr/bin/env python3
"""Loopback SOCKS5 fixture that counts successful domain-form CONNECTs."""

import select
import socket
import socketserver
import struct
import sys


def read_exact(sock, size):
    result = bytearray()
    while len(result) < size:
        data = sock.recv(size - len(result))
        if not data:
            raise EOFError
        result.extend(data)
    return bytes(result)


class SocksHandler(socketserver.BaseRequestHandler):
    def reply(self, code):
        self.request.sendall(bytes((5, code, 0, 1)) + bytes(6))

    def handle(self):
        sock = self.request
        sock.settimeout(10)
        try:
            version, count = read_exact(sock, 2)
            methods = read_exact(sock, count)
            if version != 5 or 0 not in methods:
                sock.sendall(b"\x05\xff")
                return
            sock.sendall(b"\x05\x00")
            version, command, reserved, address_type = read_exact(sock, 4)
            if (version, command, reserved) != (5, 1, 0):
                self.reply(7)
                return
            if address_type != 3:
                self.reply(8)
                return
            host = read_exact(sock, read_exact(sock, 1)[0]).decode("ascii")
            port = struct.unpack("!H", read_exact(sock, 2))[0]
            if not host.lower().endswith(".test") or port < 18000:
                self.reply(4)
                return
            try:
                origin = socket.create_connection(("127.0.0.1", port), timeout=5)
            except OSError:
                self.reply(5)
                return
            with origin:
                print(f"CONNECT {host}:{port}", flush=True)
                self.reply(0)
                self.splice(sock, origin)
        except (EOFError, OSError, UnicodeError):
            return

    @staticmethod
    def splice(client, origin):
        client.settimeout(10)
        origin.settimeout(10)
        peers = {client: origin, origin: client}
        while peers:
            ready, _, _ = select.select(list(peers), [], [], 10)
            if not ready:
                return
            for source in ready:
                data = source.recv(65536)
                if data:
                    peers[source].sendall(data)
                else:
                    peers.pop(source).shutdown(socket.SHUT_WR)


class SocksServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1])
    if not 18000 <= port <= 65535:
        sys.exit("fake_socks.py requires a test port from 18000 to 65535")
    with SocksServer(("127.0.0.1", port), SocksHandler) as server:
        print(f"ready on {port}", flush=True)
        server.serve_forever()
