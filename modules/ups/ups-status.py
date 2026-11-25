#!/usr/bin/env python3
"""
The UPS battery for the portal's Battery tile, as JSON on http://127.0.0.1:3011/ups.json.

Runs as obento-ups-status.service (module ups, with the domain module). Each request asks NUT (upsc) for the first UPS it knows, so it
reads the same values that decide the low-battery shutdown. Read-only: it never sends commands to
the UPS.

  {"power": "Charging", "charge": 97, "runtime": 6324}

runtime is in seconds. With no UPS connected, power says so and the numbers are null.
"""
import json, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ADDRESS = ("127.0.0.1", 3011)


def upsc(*args):
    out = subprocess.run(["upsc", *args], capture_output=True, text=True, timeout=5)
    return out.stdout if out.returncode == 0 else ""


def number(value):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def power(status):
    """One short state from NUT's ups.status flags, the most urgent first (LB low battery, OB on battery,
    RB replace battery, CHRG charging, OL on mains)."""
    flags = set(status.split())
    for flag, words in (("LB", "Battery low"), ("OB", "On battery"), ("RB", "Replace battery"),
                        ("CHRG", "Charging"), ("OL", "Mains")):
        if flag in flags:
            return words
    return "No UPS connected" if not flags else status


def read_ups():
    names = upsc("-l").split()
    values = {}
    if names:
        for line in upsc(f"{names[0]}@localhost").splitlines():
            key, _, value = line.partition(": ")
            values[key] = value.strip()
    return {
        "power": power(values.get("ups.status", "")),
        "charge": number(values.get("battery.charge")),
        "runtime": number(values.get("battery.runtime")),
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/ups.json":
            self.send_error(404)
            return
        try:
            body = json.dumps(read_ups()).encode()
        except (OSError, subprocess.SubprocessError) as e:
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
