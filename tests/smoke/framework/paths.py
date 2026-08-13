"""Where a smoke run writes its artifacts.

Everything a run produces -- per-test serial transcripts, the failed/ copies,
qemu's stdout, the timing/profile report -- lands in one directory so a run can
be kept whole and compared against another one. The remote runner
(scripts/remote_smoke_tui.py) points this at a numbered per-run directory
(``logs/1``, ``logs/2``, ...); a plain local ``pytest tests/smoke`` keeps the
old flat ``logs/``.
"""

import os
from pathlib import Path


def smoke_log_dir() -> Path:
    """The directory this run writes its logs to (created on demand)."""
    return Path(os.environ.get("YASOS_SMOKE_LOG_DIR", "").strip() or "logs")
