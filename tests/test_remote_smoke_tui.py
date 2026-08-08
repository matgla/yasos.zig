from argparse import Namespace
import importlib.util
import os
from pathlib import Path
import sys


REPO_ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = REPO_ROOT / "scripts" / "remote_smoke_tui.py"


def _load_remote_smoke_tui():
    module_name = "test_remote_smoke_tui_module"
    spec = importlib.util.spec_from_file_location(module_name, MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec is not None and spec.loader is not None
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


remote_smoke_tui = _load_remote_smoke_tui()


def _default_args(**overrides):
    values = {
        "test_retries": None,
        "with_gcc_torture": None,
        "smoke_tcc_opt_level": None,
        "gcc_test_suite_only": False,
        "profile": False,
        "extra_tcc_cflags": None,
        "pytest_args": None,
        "tests": None,
        "log_cli_level": None,
        "rerun_failed": False,
    }
    values.update(overrides)
    return Namespace(**values)


class _FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


def _tailer(tmp_path, monkeypatch, stream_after=30.0):
    """A tailer over *tmp_path* whose emitted lines land in the returned list."""
    emitted = []
    monkeypatch.setattr(remote_smoke_tui, "_emit", emitted.append)
    clock = _FakeClock()
    tailer = remote_smoke_tui._LogTailer(tmp_path, stream_after=stream_after, clock=clock)
    # Streaming only starts once the remote pytest phase does; every test here
    # is about what happens after that point.
    tailer.note_output("==== test session starts ====")
    return tailer, clock, emitted


def _write_log(tmp_path, name, text, mtime):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    os.utime(path, (mtime, mtime))
    return path


def test_log_tailer_stays_quiet_for_a_fast_test(tmp_path, monkeypatch):
    tailer, clock, emitted = _tailer(tmp_path, monkeypatch)

    _write_log(tmp_path, "fast.txt", "prompt\n", mtime=10.0)
    tailer.poll()
    clock.advance(10.0)
    tailer.poll()

    # Only the "fetched" note; the transcript itself is not replayed.
    assert emitted == [f"[log sync] 1 new log(s) fetched (1 total in {tmp_path})"]


def test_log_tailer_streams_the_stuck_test_log(tmp_path, monkeypatch):
    tailer, clock, emitted = _tailer(tmp_path, monkeypatch)

    _write_log(tmp_path, "stuck.txt", "tcc 31_args.c\n", mtime=10.0)
    tailer.poll()
    emitted.clear()

    clock.advance(30.0)
    tailer.poll()
    assert emitted[0] == "[log tail] stuck.txt still running after 30.0s; streaming its log"
    assert emitted[1] == "  | tcc 31_args.c"

    # Output appended while the test is still running is streamed as it lands.
    emitted.clear()
    _write_log(tmp_path, "stuck.txt", "tcc 31_args.c\npartial output\n", mtime=45.0)
    clock.advance(5.0)
    tailer.poll()
    assert emitted == ["  | partial output"]


def test_log_tailer_replays_only_the_last_context_lines(tmp_path, monkeypatch):
    tailer, clock, emitted = _tailer(tmp_path, monkeypatch)
    lines = [f"line {index}" for index in range(200)]

    _write_log(tmp_path, "stuck.txt", "\n".join(lines) + "\n", mtime=10.0)
    tailer.poll()
    emitted.clear()
    clock.advance(30.0)
    tailer.poll()

    context = remote_smoke_tui.LOG_STREAM_CONTEXT_LINES
    assert emitted[1] == f"[log tail] ... {200 - context} earlier line(s) omitted"
    assert emitted[2:] == [f"  | line {index}" for index in range(200 - context, 200)]


def test_log_tailer_reports_a_log_that_stopped_growing(tmp_path, monkeypatch):
    tailer, clock, emitted = _tailer(tmp_path, monkeypatch)

    _write_log(tmp_path, "stuck.txt", "tcc 31_args.c\n", mtime=10.0)
    tailer.poll()
    clock.advance(30.0)
    tailer.poll()
    emitted.clear()

    clock.advance(remote_smoke_tui.LOG_STREAM_IDLE_NOTICE_SECONDS)
    tailer.poll()

    assert emitted == ["[log tail] stuck.txt: no new output, 1m30s in flight"]


def test_log_tailer_follows_the_newest_log_and_drops_the_previous_one(tmp_path, monkeypatch):
    tailer, clock, emitted = _tailer(tmp_path, monkeypatch)

    _write_log(tmp_path, "first.txt", "first test\n", mtime=10.0)
    tailer.poll()
    clock.advance(30.0)
    tailer.poll()

    # The next test opens its own log, so the first one is no longer in flight.
    _write_log(tmp_path, "second.txt", "second test\n", mtime=60.0)
    clock.advance(5.0)
    tailer.poll()
    emitted.clear()

    # Late writes to the finished test's log must not be streamed...
    _write_log(tmp_path, "first.txt", "first test\nteardown\n", mtime=61.0)
    clock.advance(5.0)
    _write_log(tmp_path, "second.txt", "second test\nstill going\n", mtime=70.0)
    tailer.poll()
    assert emitted == []

    # ...and once the second test is the stuck one, it streams instead.
    clock.advance(30.0)
    tailer.poll()
    assert emitted[0].startswith("[log tail] second.txt still running")
    assert emitted[1:] == ["  | second test", "  | still going"]


def test_log_tailer_announces_each_new_log_once(tmp_path, monkeypatch):
    tailer, clock, emitted = _tailer(tmp_path, monkeypatch)

    _write_log(tmp_path, "first.txt", "first\n", mtime=10.0)
    tailer.poll()
    clock.advance(5.0)
    tailer.poll()
    _write_log(tmp_path, "second.txt", "second\n", mtime=20.0)
    clock.advance(5.0)
    tailer.poll()

    assert emitted == [
        f"[log sync] 1 new log(s) fetched (1 total in {tmp_path})",
        f"[log sync] 1 new log(s) fetched (2 total in {tmp_path})",
    ]


def test_log_tailer_streaming_can_be_disabled(tmp_path, monkeypatch):
    tailer, clock, emitted = _tailer(tmp_path, monkeypatch, stream_after=0.0)

    _write_log(tmp_path, "stuck.txt", "tcc 31_args.c\n", mtime=10.0)
    tailer.poll()
    emitted.clear()
    clock.advance(600.0)
    tailer.poll()

    assert emitted == []
    assert tailer.streaming is False


def test_log_tailer_ignores_logs_fetched_before_pytest_starts(tmp_path, monkeypatch):
    """The remote clears logs/ only after flashing, so early polls fetch the
    previous run's logs; streaming one of them would show an unrelated test."""
    emitted = []
    monkeypatch.setattr(remote_smoke_tui, "_emit", emitted.append)
    clock = _FakeClock()
    tailer = remote_smoke_tui._LogTailer(tmp_path, stream_after=30.0, clock=clock)

    _write_log(tmp_path, "previous_run.txt", "old transcript\n", mtime=10.0)
    tailer.poll()
    emitted.clear()
    clock.advance(600.0)
    tailer.poll()

    assert emitted == []
    assert tailer.streaming is False


def test_log_tailer_starts_streaming_after_the_remote_clears_the_logs(tmp_path, monkeypatch):
    emitted = []
    monkeypatch.setattr(remote_smoke_tui, "_emit", emitted.append)
    clock = _FakeClock()
    tailer = remote_smoke_tui._LogTailer(tmp_path, stream_after=30.0, clock=clock)

    stale = _write_log(tmp_path, "previous_run.txt", "old transcript\n", mtime=10.0)
    tailer.poll()
    clock.advance(600.0)

    # rsync --delete mirrors the remote wipe; pytest starts right after it.
    stale.unlink()
    tailer.poll()
    _write_log(tmp_path, "current.txt", "tcc 31_args.c\n", mtime=700.0)
    tailer.poll()
    emitted.clear()

    clock.advance(30.0)
    tailer.poll()

    assert emitted[0] == "[log tail] current.txt still running after 30.0s; streaming its log"
    assert emitted[1:] == ["  | tcc 31_args.c"]


def test_apply_runtime_pytest_overrides_keeps_log_stream_after_out_of_the_cache():
    config = remote_smoke_tui.apply_runtime_pytest_overrides(
        dict(remote_smoke_tui.DEFAULT_CONFIG),
        _default_args(log_stream_after=5.0),
    )

    assert config["log_stream_after"] == 5.0
    assert "log_stream_after" not in remote_smoke_tui.DEFAULT_CONFIG


def test_apply_runtime_pytest_overrides_sets_smoke_tcc_opt_level():
    config = remote_smoke_tui.apply_runtime_pytest_overrides(
        dict(remote_smoke_tui.DEFAULT_CONFIG),
        _default_args(smoke_tcc_opt_level="-O1"),
    )

    assert config["smoke_tcc_opt_level"] == "-O1"


def test_default_smoke_tcc_opt_levels_cover_the_whole_matrix():
    # Remote smoke is the only place the suites meet real silicon, so a level
    # missing from the default is a level the board never proves.
    assert remote_smoke_tui.DEFAULT_CONFIG["smoke_tcc_opt_level"] == "-O0 -O1 -O2"


def test_normalize_smoke_tcc_opt_levels_accepts_every_spelling():
    normalize = remote_smoke_tui.normalize_smoke_tcc_opt_levels

    assert normalize("-O1") == "-O1"
    assert normalize("O1") == "-O1"
    assert normalize("1") == "-O1"
    assert normalize("all") == "-O0 -O1 -O2"
    assert normalize("-O0,-O2") == "-O0 -O2"
    assert normalize(" -O2  -O0 ") == "-O2 -O0"
    # Duplicates collapse rather than running the same level twice.
    assert normalize("-O1 -O1") == "-O1"
    assert normalize("") == ""


def test_normalize_smoke_tcc_opt_levels_rejects_unsupported_levels():
    for value in ("-O3", "-Os", "junk"):
        try:
            remote_smoke_tui.normalize_smoke_tcc_opt_levels(value)
        except ValueError:
            continue
        raise AssertionError(f"{value!r} should not be accepted as an -O level")


def test_opt_level_flag_absorbs_space_separated_values():
    # argparse reads a bare "-O1" as an option, not a value, so the documented
    # spelling only works because the folder rewrites it first.
    fold = remote_smoke_tui.fold_smoke_tcc_opt_level_args

    assert fold(["--smoke-tcc-opt-level", "-O1"]) == ["--smoke-tcc-opt-levels=-O1"]
    assert fold(["--smoke-tcc-opt-levels", "-O0", "-O2"]) == ["--smoke-tcc-opt-levels=-O0 -O2"]
    # Absorbing stops at the next flag, and at a value meant for another one.
    assert fold(["--smoke-tcc-opt-levels", "-O1", "--tests", "a.py"]) == [
        "--smoke-tcc-opt-levels=-O1",
        "--tests",
        "a.py",
    ]
    # A level-shaped but unsupported value is still absorbed, so the type
    # function rejects it by name instead of argparse calling it an unknown
    # option.
    assert fold(["--smoke-tcc-opt-levels", "-O9"]) == ["--smoke-tcc-opt-levels=-O9"]
    assert fold(["--run-cached"]) == ["--run-cached"]


def test_merge_config_keeps_a_multi_level_selection():
    merged = remote_smoke_tui.merge_config({"smoke_tcc_opt_level": "0,2"})

    assert merged["smoke_tcc_opt_level"] == "-O0 -O2"


def test_merge_config_falls_back_when_the_cached_level_is_unusable():
    merged = remote_smoke_tui.merge_config({"smoke_tcc_opt_level": "-O9"})

    assert merged["smoke_tcc_opt_level"] == remote_smoke_tui.SMOKE_TCC_ALL_OPT_LEVELS


def test_legacy_cache_migrates_the_old_single_level_default():
    migrated, notes = remote_smoke_tui.migrate_cached_config({"smoke_tcc_opt_level": "-O0"})

    assert migrated["smoke_tcc_opt_level"] == "-O0 -O1 -O2"
    assert migrated["config_version"] == remote_smoke_tui.CONFIG_VERSION
    assert notes


def test_migration_leaves_a_deliberately_chosen_level_alone():
    # -O1 differs from the old default, so somebody picked it on purpose.
    migrated, notes = remote_smoke_tui.migrate_cached_config({"smoke_tcc_opt_level": "-O1"})

    assert migrated["smoke_tcc_opt_level"] == "-O1"
    assert notes == []

    # And once migrated, -O0 stays -O0: the migration runs once, not per run.
    current, notes = remote_smoke_tui.migrate_cached_config(
        {"smoke_tcc_opt_level": "-O0", "config_version": remote_smoke_tui.CONFIG_VERSION}
    )

    assert current["smoke_tcc_opt_level"] == "-O0"
    assert notes == []


def test_cycle_smoke_tcc_opt_levels_survives_a_custom_selection():
    cycle = remote_smoke_tui.cycle_smoke_tcc_opt_levels

    assert cycle("-O0 -O1 -O2", 1) == "-O0"
    assert cycle("-O0", -1) == "-O0 -O1 -O2"
    # A combination the presets do not list (or a corrupt value) lands on the
    # default rather than raising out of the TUI's key handler.
    assert cycle("-O0 -O2", 1) == "-O0 -O1 -O2"
    assert cycle("junk", 1) == "-O0 -O1 -O2"


def test_collect_smoke_tests_exports_selected_smoke_opt_level(monkeypatch):
    captured = {}

    class CompletedProcess:
        returncode = 0
        stdout = "tests/smoke/tcc_suite_test.py::test_run_gcc_compile_torture_suite[gcc_compile/example[-O1]]\n"
        stderr = ""

    def fake_run(cmd, cwd, env, text, stdout, stderr, check):
        captured["cmd"] = cmd
        captured["cwd"] = cwd
        captured["env"] = env
        return CompletedProcess()

    monkeypatch.setattr(remote_smoke_tui.subprocess, "run", fake_run)

    collected = remote_smoke_tui.collect_smoke_tests(["tests/smoke", "-m", "gcc_torture"], True, "-O1")

    assert collected == [
        "tests/smoke/tcc_suite_test.py::test_run_gcc_compile_torture_suite[gcc_compile/example[-O1]]"
    ]
    assert captured["cwd"] == remote_smoke_tui.REPO_ROOT
    assert captured["env"]["YASOS_SMOKE_ENABLE_GCC_TORTURE"] == "1"
    assert captured["env"]["YASOS_SMOKE_TCC_OPT_LEVELS"] == "-O1"