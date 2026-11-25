#!/usr/bin/env python3
"""
Space on the hard drives (the ZFS pool) for the portal's Drives gauge, as JSON on
http://127.0.0.1:3012/pool.json.

Runs as obento-pool-status.service when the domain module is on. Each request asks ZFS, so it shows what
'zfs list' does: used and available as files see them (after the mirror and ZFS's reserve), across every
pool, with the worst health. Read-only.

  {"used": 1234567890, "free": 17000000000000, "health": "ONLINE"}

Sizes are in bytes. Before the pool exists (RUNBOOK step 5) the sizes are null.
"""
import json, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ADDRESS = ("127.0.0.1", 3012)
# Worst first: the gauge shows the worst health of any pool.
HEALTH = ["FAULTED", "UNAVAIL", "SUSPENDED", "DEGRADED", "REMOVED", "OFFLINE", "ONLINE"]


def run(*args):
    out = subprocess.run(args, capture_output=True, text=True, timeout=5)
    return out.stdout if out.returncode == 0 else ""


def read_pool():
    used = free = None
    for line in run("zfs", "list", "-Hp", "-d", "0", "-o", "used,avail").splitlines():
        u, f = (int(x) for x in line.split())
        used, free = (used or 0) + u, (free or 0) + f
    states = run("zpool", "list", "-H", "-o", "health").split()
    health = min(states, key=lambda s: HEALTH.index(s) if s in HEALTH else 0) if states else None
    return {"used": used, "free": free, "health": health}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/pool.json":
            self.send_error(404)
            return
        try:
            body = json.dumps(read_pool()).encode()
        except (OSError, ValueError, subprocess.SubprocessError) as e:
            self.send_error(503, str(e))
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # the portal asks every few seconds; don't fill the journal


if __name__ == "__main__":
    ThreadingHTTPServer(ADDRESS, Handler).serve_forever()
