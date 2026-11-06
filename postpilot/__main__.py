"""Single entrypoint for the container: `python -m postpilot api|worker`."""

from __future__ import annotations

import argparse
import sys

from postpilot.config import Settings
from postpilot.logging_config import configure_logging


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="postpilot")
    parser.add_argument("command", choices=["api", "worker"])
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args(argv)

    settings = Settings.from_env()
    configure_logging(settings.log_level)

    if args.command == "worker":
        from postpilot import worker

        return worker.main(settings)

    import uvicorn

    from postpilot.api import create_app

    uvicorn.run(create_app(settings), host=args.host, port=args.port, log_config=None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
