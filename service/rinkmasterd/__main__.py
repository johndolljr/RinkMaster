"""Run the service: python3 -m rinkmasterd [--host 0.0.0.0] [--port 8472] [--roms DIR] [--configs DIR]"""
import argparse
import signal
import sys

from . import __version__
from .cache import InventoryCache
from .server import Context, make_server


def parse_args(argv=None):
    ap = argparse.ArgumentParser(prog="rinkmasterd", description="RinkMaster cabinet service")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8472)
    ap.add_argument("--roms", default="/home/pi/RetroPie/roms")
    ap.add_argument("--configs", default="/opt/retropie/configs")
    return ap.parse_args(argv)


def build_server(args):
    return make_server(args.host, args.port, Context(InventoryCache(args.roms, args.configs), __version__))


def main(argv=None) -> int:  # pragma: no cover - blocking run loop, exercised by the deployed service
    args = parse_args(argv)
    httpd = build_server(args)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    sys.stderr.write("rinkmasterd %s listening on %s:%d (roms %s)\n" % (__version__, args.host, args.port, args.roms))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
