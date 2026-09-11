"""Live progress reporting for long-running smoke tests.

``pytest -v`` writes the nodeid of a test *without* a trailing newline before
the test starts and only terminates that line once the test finishes.  Every
consumer that reads the smoke output line by line (``remote_smoke_tui.py``
streams the ssh pipe with ``for line in proc.stdout``, CI log viewers, ``tee``
into a pager) therefore shows nothing at all while a test runs -- so a test
that takes two minutes, or hangs forever on a wedged board, is invisible.

This module adds two things on top of pytest's own reporting:

* a ``RUNNING`` line once a test has been in flight longer than
  ``YASOS_SMOKE_ANNOUNCE_AFTER`` seconds (default 1s), repeated every
  ``YASOS_SMOKE_ANNOUNCE_EVERY`` seconds (default 30s) with the elapsed time,
  so a stuck test is obvious while it is still stuck, and
* the wall time each test took, appended to the PASSED/FAILED/SKIPPED word.

The ``RUNNING`` line is written from a background thread, because the main
thread is blocked inside the test at that point.
"""

from __future__ import annotations

import os
import threading
import time


def _env_seconds(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return max(value, 0.0)


# 0 disables: ANNOUNCE_AFTER=0 turns the RUNNING lines off entirely,
# ANNOUNCE_EVERY=0 keeps the first one but drops the repeats.
ANNOUNCE_AFTER_SECONDS = _env_seconds("YASOS_SMOKE_ANNOUNCE_AFTER", 1.0)
ANNOUNCE_EVERY_SECONDS = _env_seconds("YASOS_SMOKE_ANNOUNCE_EVERY", 30.0)


def format_duration(seconds: float) -> str:
    """Render *seconds* compactly: ``0.42s``, ``12.3s``, ``2m03s``."""
    if seconds < 10.0:
        return f"{seconds:.2f}s"
    if seconds < 60.0:
        return f"{seconds:.1f}s"
    minutes, remainder = divmod(int(round(seconds)), 60)
    return f"{minutes}m{remainder:02d}s"


class RunningTestAnnouncer:
    """Announce the in-flight test from a background thread.

    A single thread serves the whole session; `start` and `finish` hand it the
    nodeid that is currently running.  They are called from
    ``pytest_runtest_logstart`` / ``pytest_runtest_logfinish``, so the elapsed
    time starts counting before setup -- a board that hangs while being
    reflashed in a fixture gets announced too.  Once the result word has been
    written there is no pending nodeid line left to work with, so a slow
    teardown is not announced; the last RUNNING line still names the test.
    """

    def __init__(self, config, announce_after: float, announce_every: float):
        # The terminal reporter is registered by its own pytest_configure, which
        # runs after this conftest's, so it is looked up lazily.
        self._config = config
        self._announce_after = announce_after
        self._announce_every = announce_every
        self._condition = threading.Condition()
        self._nodeid: str | None = None
        self._started_at = 0.0
        self._generation = 0
        self._stopped = False
        self._thread: threading.Thread | None = None

    @property
    def enabled(self) -> bool:
        if self._announce_after <= 0.0:
            return False
        # xdist already prints one line per test start (the controller cannot
        # keep a pending line open while several workers report), so nothing is
        # hidden there -- and writing into that layout only garbles it.
        if hasattr(self._config, "workerinput"):
            return False
        if self._config.getoption("dist", "no") != "no":
            return False
        # Without -s the per-test capture swallows anything written to stdout
        # while a test runs; the announce line would end up in the test's
        # captured output instead of on the console. Both smoke runners use -s.
        return self._config.getoption("capture", "fd") == "no"

    def start(self, nodeid: str) -> None:
        if not self.enabled:
            return
        with self._condition:
            self._nodeid = nodeid
            self._started_at = time.monotonic()
            self._generation += 1
            self._condition.notify_all()
        if self._thread is None:
            self._thread = threading.Thread(
                target=self._run, name="smoke-progress", daemon=True
            )
            self._thread.start()

    def finish(self) -> None:
        if not self.enabled:
            return
        with self._condition:
            self._nodeid = None
            self._condition.notify_all()

    def stop(self) -> None:
        with self._condition:
            self._stopped = True
            self._nodeid = None
            self._condition.notify_all()
        thread = self._thread
        self._thread = None
        if thread is not None:
            thread.join(timeout=2)

    def _run(self) -> None:
        # Generations are only ever serviced once, so falling out of the inner
        # loop (repeats disabled) parks the thread until the *next* test starts
        # instead of re-announcing the current one.
        serviced_generation = 0
        with self._condition:
            while not self._stopped:
                while not self._stopped and (
                    self._nodeid is None or self._generation == serviced_generation
                ):
                    self._condition.wait()
                if self._stopped:
                    return
                generation = self._generation
                serviced_generation = generation
                started_at = self._started_at
                deadline = started_at + self._announce_after
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining > 0.0:
                        self._condition.wait(remaining)
                    # Test finished, next one started, or session over: this
                    # deadline is stale, go wait for the next test.
                    if (
                        self._stopped
                        or self._nodeid is None
                        or self._generation != generation
                    ):
                        break
                    if time.monotonic() < deadline:
                        continue
                    self._announce(time.monotonic() - started_at)
                    if self._announce_every <= 0.0:
                        break
                    deadline += self._announce_every

    def _announce(self, elapsed: float) -> None:
        """Close pytest's pending ``<nodeid>`` line, then re-open it.

        Closing the line is what makes the in-flight test visible to a
        line-buffered reader; re-opening it with the same prefix (and leaving
        ``currentfspath`` alone) means pytest's own result write still appends
        ``PASSED``/``FAILED`` to a line that carries the nodeid, so both lines
        stay greppable and no blank lines appear in between.
        """
        # None under xdist, where the workers print through the controller.
        reporter = self._config.pluginmanager.getplugin("terminalreporter")
        writer = getattr(reporter, "_tw", None)
        prefix = getattr(reporter, "currentfspath", None)
        # A str prefix means the verbose one-line-per-test layout is active.
        # Under -q/non-verbose the pending line holds progress characters
        # instead, so leave that output alone.
        if writer is None or not isinstance(prefix, str) or not prefix:
            return
        # The prefix pytest wrote already ends with a space.  cyan marks it
        # apart from the green/red result words it sits between; the markup is
        # a no-op unless pytest was given --color=yes (the remote runner passes
        # it whenever its own colour is on).
        writer.write(f"RUNNING {format_duration(elapsed)}", cyan=True)
        writer.line()
        writer.write(prefix, flush=True)
