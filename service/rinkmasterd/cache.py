"""Signature-invalidated cache of the cabinet inventory.

The signature is the mtimes of the system folders under the ROM dir (they change when a ROM is added or
removed) and of the emulators.cfg files. A cache older than `max_age` seconds is rebuilt anyway to catch
in-place changes, and `refresh()` forces a rebuild.
"""
from __future__ import annotations

import hashlib
import json
import os
import socket
import threading
import time
from datetime import datetime, timezone
from typing import Optional

from . import inventory


class Result:
    def __init__(self, body: bytes, etag: str, hit: bool, inv: dict):
        self.body = body
        self.etag = etag
        self.hit = hit
        self.inventory = inv


class InventoryCache:
    def __init__(self, roms_path: str, configs_path: str, hostname: Optional[str] = None, max_age: float = 60.0):
        self.roms_path = roms_path
        self.configs_path = configs_path
        self.hostname = hostname or socket.gethostname().split(".")[0]
        self.max_age = max_age
        self._lock = threading.Lock()
        self._sig = None
        self._built_at = 0.0
        self._result: Optional[Result] = None

    def signature(self):
        parts = []
        try:
            for e in sorted(os.scandir(self.roms_path), key=lambda e: e.name):
                if e.is_dir() and not e.name.startswith("."):
                    parts.append((e.name, e.stat().st_mtime_ns))
        except OSError:
            pass
        cfgs = [os.path.join(self.configs_path, "all", "emulators.cfg")]
        try:
            cfgs += [os.path.join(self.configs_path, d, "emulators.cfg") for d in sorted(os.listdir(self.configs_path))]
        except OSError:
            pass
        for path in sorted(set(cfgs)):
            try:
                st = os.stat(path)
                parts.append((path, st.st_mtime_ns, st.st_size))
            except OSError:
                pass
        return tuple(parts)

    def _build(self, sig) -> Result:
        inv = inventory.build_inventory(self.roms_path, self.configs_path)
        content = json.dumps(inv, sort_keys=True, separators=(",", ":"))
        etag = '"%s"' % hashlib.sha1(content.encode()).hexdigest()[:16]
        out = dict(inv)
        out["machine"] = self.hostname
        out["generatedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        body = json.dumps(out, sort_keys=True).encode()
        self._sig, self._built_at = sig, time.monotonic()
        self._result = Result(body, etag, False, inv)
        return self._result

    def get(self) -> Result:
        with self._lock:
            sig = self.signature()
            fresh = self._result is not None and sig == self._sig and (time.monotonic() - self._built_at) <= self.max_age
            if fresh:
                r = self._result
                return Result(r.body, r.etag, True, r.inventory)
            return self._build(sig)

    def refresh(self) -> Result:
        with self._lock:
            return self._build(self.signature())
