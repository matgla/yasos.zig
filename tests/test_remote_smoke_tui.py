from argparse import Namespace
import importlib.util
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


def test_apply_runtime_pytest_overrides_sets_smoke_tcc_opt_level():
    config = remote_smoke_tui.apply_runtime_pytest_overrides(
        dict(remote_smoke_tui.DEFAULT_CONFIG),
        _default_args(smoke_tcc_opt_level="-O1"),
    )

    assert config["smoke_tcc_opt_level"] == "-O1"


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