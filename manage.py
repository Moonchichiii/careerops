#!/usr/bin/env python
from __future__ import annotations

import os
import sys


def main() -> None:
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings.local")

    try:
        from django.core.management import execute_from_command_line
    except ImportError as exc:
        msg = "Django is not available. Run `uv sync --locked --all-groups` first."
        raise ImportError(msg) from exc

    execute_from_command_line(sys.argv)


if __name__ == "__main__":
    main()
