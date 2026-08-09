import contextlib
import json
from pathlib import Path
import shlex
import sys
import types

import pytest


sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke import tcc_suite_test as suite
from smoke.framework.file_transfer import TransferError


class FakeSerial:
    def __init__(self):
        self.timeout = 1.0


class FakeSession:
    def __init__(self, responses):
        self.serial = FakeSerial()
        self.commands = []
        self._responses = list(responses)
        self.confirmed_uploads = {}
        self.confirmed_uploads_generation = 0

    def write_command(self, command: str) -> None:
        self.commands.append(command)

    @contextlib.contextmanager
    def timeout(self, seconds):
        """Match Session.timeout: the post-compile cleanup runs inside one."""
        yield

    def wait_for_prompt_except_logs(self, timeout=None):
        assert self._responses, "unexpected wait_for_prompt_except_logs call"
        response = self._responses.pop(0)
        return list(response)

    def wait_for_prompt_streaming(self, on_line=None, timeout=None):
        response = self.wait_for_prompt_except_logs()
        if on_line is not None:
            for line in response:
                if on_line(line):
                    return response, True
        return response, False


def _cleanup_command(session: FakeSession) -> str | None:
    cleanup_commands = [command for command in session.commands if command.startswith("rm -f ")]
    return cleanup_commands[-1] if cleanup_commands else None


def _copy_commands(session: FakeSession) -> list[str]:
    return [command for command in session.commands if command.startswith("cp ")]


def test_compile_testcase_keeps_single_source_in_remote_tree(monkeypatch):
    testcase = suite.TccTestCase(
        test_id="00_assignment.c",
        name="00_assignment.c",
        sources=("00_assignment.c",),
        expected_lines=(),
    )
    # One reply per read compile_testcase performs: the compile, the run, the
    # cleanup. A source already in the remote tree costs no reads of its own.
    session = FakeSession([
        [f"{suite.COMPILE_MARKER_PREFIX}0"],
        [f"{suite.EXIT_MARKER_PREFIX}0"],
        [],
    ])
    monkeypatch.setattr(suite, "get_remote_hash", lambda remote_path, _: "a" * 64)

    suite.compile_testcase(testcase, session)

    compile_command = next(command for command in session.commands if command.startswith("tcc "))
    assert _copy_commands(session) == []
    # Derived, not spelled out: sources live in bucket directories now (see
    # "Source sharding"), and what this test is about is that the compile reads
    # the source where it lies rather than copying it to /tmp.
    assert suite.remote_source_path("00_assignment.c") in compile_command
    assert not session._responses


def test_compile_testcase_keeps_opted_out_source_in_place(monkeypatch):
    testcase = suite.TccTestCase(
        test_id="18_include.c",
        name="18_include.c",
        sources=("18_include.c",),
        expected_lines=(),
    )
    session = FakeSession([
        [f"{suite.COMPILE_MARKER_PREFIX}0"],
        [f"{suite.EXIT_MARKER_PREFIX}0"],
        [],
    ])
    monkeypatch.setattr(suite, "get_remote_hash", lambda remote_path, _: "a" * 64)

    suite.compile_testcase(testcase, session)

    compile_command = next(command for command in session.commands if command.startswith("tcc "))
    assert all(not command.startswith("cp ") for command in session.commands)
    assert suite.remote_source_path("18_include.c") in compile_command
    assert "/tmp/18_include__18_include.c" not in compile_command
    assert not session._responses


def test_compile_only_testcase_cleans_up_its_object_file(monkeypatch):
    testcase = suite.TccTestCase(
        test_id="00_assignment.c",
        name="00_assignment.c",
        sources=("00_assignment.c",),
        expected_lines=(),
        compile_only=True,
    )
    # No run read here: a compile-only case never executes the binary.
    session = FakeSession([
        [f"{suite.COMPILE_MARKER_PREFIX}0"],
        [],
    ])
    monkeypatch.setattr(suite, "get_remote_hash", lambda remote_path, _: "a" * 64)

    suite.compile_testcase(testcase, session)

    # Nothing links these objects, and the gcc-torture compile-only cases run
    # in the thousands, so the .o goes the way of every other build product --
    # leaving it behind would fill the device's RAM-backed /tmp.
    assert _cleanup_command(session) == "rm -f /tmp/00_assignment.o"
    assert not session._responses


def test_compile_testcase_does_not_copy_or_reuse_temp_sources(monkeypatch):
    testcase = suite.TccTestCase(
        test_id="60_errors_and_warnings.c[test_a]",
        name="60_errors_and_warnings.c",
        sources=("60_errors_and_warnings.c",),
        expected_lines=(),
        expected_compile_failure=True,
        expected_error_patterns=(r"60_errors_and_warnings\.c:1:\ error:\ foo",),
    )
    plan = suite._build_temp_source_reuse_marks([
        ("tests/smoke/tcc_suite_test.py::test_run_tcc_test_suite[test_a]", testcase),
        ("tests/smoke/tcc_suite_test.py::test_run_tcc_test_suite[test_b]", testcase),
    ])

    # An expected compile failure produces no binary, so there is nothing to
    # run and nothing to clean up: the compile read is the only one.
    first_session = FakeSession([
        [f"{suite.COMPILE_MARKER_PREFIX}1", "60_errors_and_warnings.c:1: error: foo"],
    ])
    second_session = FakeSession([
        [f"{suite.COMPILE_MARKER_PREFIX}1", "60_errors_and_warnings.c:1: error: foo"],
    ])
    monkeypatch.setattr(suite, "get_remote_hash", lambda remote_path, _: "a" * 64)

    suite.compile_testcase(
        testcase,
        first_session,
        current_item_id="tests/smoke/tcc_suite_test.py::test_run_tcc_test_suite[test_a]",
        temp_source_plan=plan,
    )
    suite.compile_testcase(
        testcase,
        second_session,
        current_item_id="tests/smoke/tcc_suite_test.py::test_run_tcc_test_suite[test_b]",
        temp_source_plan=plan,
    )

    assert _copy_commands(first_session) == []
    assert _cleanup_command(first_session) is None
    assert _copy_commands(second_session) == []
    assert _cleanup_command(second_session) is None
    assert not first_session._responses
    assert not second_session._responses


def test_build_temp_source_reuse_marks_tracks_first_and_last_users():
    testcase = suite.TccTestCase(
        test_id="60_errors_and_warnings.c[test_a]",
        name="60_errors_and_warnings.c",
        sources=("60_errors_and_warnings.c",),
    )
    other_testcase = suite.TccTestCase(
        test_id="00_assignment.c",
        name="00_assignment.c",
        sources=("00_assignment.c",),
    )

    plan = suite._build_temp_source_reuse_marks([
        ("first", testcase),
        ("middle", testcase),
        ("single", other_testcase),
        ("last", testcase),
    ])

    assert plan.first_users == frozenset()
    assert plan.last_users == frozenset()


def test_build_tcc_test_cases_marks_tagged_compile_failures():
    testcase = next(
        case
        for case in suite.build_tcc_test_cases()
        if case.test_id == "60_errors_and_warnings.c[test_56_btype_excess_1]"
    )

    assert testcase.expected_compile_failure is True
    assert testcase.expected_error_patterns == (
        r"60_errors_and_warnings\.c:2:\ error:\ too\ many\ basic\ types",
    )


def test_build_tcc_test_cases_marks_empty_tagged_compile_only_variants_by_source():
    compile_only_ids = {
        "60_errors_and_warnings.c[test_incomplete_array_array]",
        "60_errors_and_warnings.c[test_var_4]",
    }
    runtime_id = "60_errors_and_warnings.c[test_var_1]"

    cases = {case.test_id: case for case in suite.build_tcc_test_cases()}

    assert all(cases[test_id].compile_only is True for test_id in compile_only_ids)
    assert cases[runtime_id].compile_only is False


def test_discover_local_dependencies_includes_builtins_lib_sources():
    testcase = suite.TccTestCase(
        test_id="gcc_execute/builtins/strpbrk[-O0]",
        name="builtins/strpbrk.c",
        sources=("builtins/strpbrk.c", "builtins/strpbrk-lib.c", "builtins/lib/main.c"),
        source_dir=suite.gcc_execute_path,
    )

    upload_entries = suite._iter_testcase_upload_entries(testcase)
    dependencies = suite._discover_local_dependencies(upload_entries)
    dependency_map = {remote_name: str(local_path) for local_path, remote_name in dependencies}

    assert "builtins/lib/strpbrk.c" in dependency_map
    assert dependency_map["builtins/lib/strpbrk.c"].endswith("builtins/lib/strpbrk.c")


def test_discover_local_dependencies_includes_chk_headers_and_sources():
    testcase = suite.TccTestCase(
        test_id="gcc_execute/builtins/strcpy-chk[-O0]",
        name="builtins/strcpy-chk.c",
        sources=("builtins/strcpy-chk.c", "builtins/strcpy-chk-lib.c", "builtins/lib/main.c"),
        source_dir=suite.gcc_execute_path,
    )

    upload_entries = suite._iter_testcase_upload_entries(testcase)
    dependencies = suite._discover_local_dependencies(upload_entries)
    dependency_map = {remote_name: str(local_path) for local_path, remote_name in dependencies}

    assert "builtins/chk.h" in dependency_map
    assert dependency_map["builtins/chk.h"].endswith("builtins/chk.h")
    assert "builtins/lib/chk.c" in dependency_map
    assert dependency_map["builtins/lib/chk.c"].endswith("builtins/lib/chk.c")


@pytest.fixture
def manifest(tmp_path, monkeypatch):
    """Scratch manifest file, pristine state, and a corpus the test controls."""
    path = tmp_path / "smoke_source_manifest.json"
    corpus = {}
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_PATH", path)
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_ENABLED", True)
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_TRUST", False)
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_PUSH", False)
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_CHECK", True)
    monkeypatch.setattr(suite, "_corpus_source_hashes", lambda: dict(corpus))
    monkeypatch.setattr(
        suite, "_source_manifest_state", {"generation": None, "digest": None, "count": 0}
    )
    return types.SimpleNamespace(path=path, corpus=corpus)


def _write_manifest(path, entries):
    path.write_text(
        json.dumps({"version": suite.SOURCE_MANIFEST_VERSION, "entries": entries})
    )


def _manifest_case(tmp_path):
    """A local source plus the manifest entry that describes its device copy."""
    local_source = tmp_path / "manifest_case.c"
    local_source.write_text("int main(void) { return 0; }\n")
    remote_path = suite.remote_source_path("manifest_case.c")
    return local_source, {remote_path: suite.sha256_file(str(local_source))}


def test_source_manifest_seeds_confirmed_uploads_from_device_token(
    manifest, tmp_path, monkeypatch
):
    local_source, entries = _manifest_case(tmp_path)
    _write_manifest(manifest.path, entries)
    manifest.corpus.update(entries)
    session = FakeSession([[suite._source_manifest_digest(entries)]])

    def _unexpected_device_hash(remote_path, _session):
        raise AssertionError(f"seeded source was re-hashed on the device: {remote_path}")

    monkeypatch.setattr(suite, "get_remote_hash", _unexpected_device_hash)

    suite.ensure_source_manifest_seeded(session)

    assert session.confirmed_uploads == entries
    assert suite.upload_testcase(str(local_source), "manifest_case.c", session) == "cached"
    assert session.commands == ["cat " + shlex.quote(suite.REMOTE_MANIFEST_ID_PATH)]


def test_source_manifest_prebuilds_the_corpus_when_the_device_agrees(
    manifest, tmp_path, monkeypatch
):
    local_source, entries = _manifest_case(tmp_path)
    manifest.corpus.update(entries)
    checked = []

    def _verify(_session, corpus):
        checked.append(dict(corpus))
        return dict(corpus)

    monkeypatch.setattr(suite, "_verify_corpus_on_device", _verify)

    def _unexpected_device_hash(remote_path, _session):
        raise AssertionError(f"prebuilt source was re-hashed: {remote_path}")

    monkeypatch.setattr(suite, "get_remote_hash", _unexpected_device_hash)
    session = FakeSession([[]])  # the token write

    suite.ensure_source_manifest_seeded(session)

    assert checked == [entries]
    assert session.confirmed_uploads == entries
    assert json.loads(manifest.path.read_text())["entries"] == entries
    assert suite.upload_testcase(str(local_source), "manifest_case.c", session) == "cached"


def test_corpus_check_keeps_only_the_sources_the_device_confirmed(manifest, monkeypatch):
    corpus = {
        suite.remote_source_path("a.c"): "a" * 64,
        suite.remote_source_path("b.c"): "b" * 64,
        suite.remote_source_path("c.c"): "c" * 64,
    }
    sent = {}
    monkeypatch.setattr(
        suite,
        "serial_send_file",
        lambda session, local, remote, timeout=5.0, on_progress=None: sent.update(
            local=local, remote=remote
        ),
    )
    matched, changed, missing = sorted(corpus)
    session = FakeSession([
        [],  # mkdir -p
        [
            f"{matched}: OK",
            f"{changed}: FAILED",
            f"sha256sum: {missing}: No such file or directory",
        ],
    ])

    verified = suite._verify_corpus_on_device(session, corpus)

    assert verified == {matched: corpus[matched]}
    assert sent["remote"] == suite.REMOTE_MANIFEST_CHECK_PATH
    assert Path(sent["local"]).read_text().splitlines()[0] == f"{corpus[matched]}  {matched}"
    assert session.commands[-1] == (
        "sha256sum -c " + shlex.quote(suite.REMOTE_MANIFEST_CHECK_PATH)
    )


def test_source_manifest_verifies_per_file_when_the_device_disagrees(
    manifest, tmp_path, monkeypatch
):
    local_source, entries = _manifest_case(tmp_path)
    manifest.corpus.update(entries)
    monkeypatch.setattr(suite, "_verify_corpus_on_device", lambda _session, _corpus: {})
    hashed = []

    def _device_hash(remote_path, _session):
        hashed.append(remote_path)
        return next(iter(entries.values()))

    monkeypatch.setattr(suite, "get_remote_hash", _device_hash)
    session = FakeSession([])

    suite.ensure_source_manifest_seeded(session)

    assert session.confirmed_uploads == {}
    assert not manifest.path.exists()
    assert suite.upload_testcase(str(local_source), "manifest_case.c", session) == "cached"
    assert hashed == list(entries)


def test_source_manifest_lazy_mode_costs_the_device_nothing(
    manifest, tmp_path, monkeypatch
):
    _, entries = _manifest_case(tmp_path)
    manifest.corpus.update(entries)
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_CHECK", False)

    def _unexpected_check(_session, _corpus):
        raise AssertionError("the corpus check must be opt-in")

    monkeypatch.setattr(suite, "_verify_corpus_on_device", _unexpected_check)
    session = FakeSession([])

    suite.ensure_source_manifest_seeded(session)

    # Nothing seeded and nothing sent: the tests verify their own sources as
    # they reach them, and the flush banks each one into the map.
    assert session.confirmed_uploads == {}
    assert session.commands == []


def test_source_manifest_trust_mode_skips_the_device_check(manifest, tmp_path, monkeypatch):
    _, entries = _manifest_case(tmp_path)
    manifest.corpus.update(entries)
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_TRUST", True)

    def _unexpected_check(_session, _corpus):
        raise AssertionError("trust mode must not check the corpus on the device")

    monkeypatch.setattr(suite, "_verify_corpus_on_device", _unexpected_check)
    session = FakeSession([[]])  # the token write

    suite.ensure_source_manifest_seeded(session)

    assert session.confirmed_uploads == entries


@pytest.fixture
def push_mode(manifest, monkeypatch, tmp_path):
    """Push bootstrap with the batch transfer replaced by a recorder."""
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_CHECK", False)
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_PUSH", True)

    def _unexpected_check(_session, _corpus):
        raise AssertionError("push mode must not ask the device to hash anything")

    monkeypatch.setattr(suite, "_verify_corpus_on_device", _unexpected_check)

    pushed = []

    def _send_files(_session, transfers, timeout=30.0, on_progress=None):
        transfers = list(transfers)
        pushed.extend(remote for _local, remote in transfers)
        return sum(len(Path(local).read_bytes()) for local, _remote in transfers)

    monkeypatch.setattr(suite, "serial_send_files", _send_files)

    # Local files for whatever the corpus names, so the push has something to
    # size and send.
    def _corpus_files():
        files = {}
        for index, remote_path in enumerate(manifest.corpus):
            local = tmp_path / f"push_{index}.c"
            local.write_text(f"/* {remote_path} */\n")
            files[remote_path] = str(local)
        return files

    monkeypatch.setattr(suite, "_corpus_source_files", _corpus_files)
    return types.SimpleNamespace(pushed=pushed)


def test_push_progress_line_reports_bar_counts_rate_and_eta():
    line = suite._format_push_progress(
        done=1000, total=4000, sent=1024 * 1024, total_bytes=4 * 1024 * 1024,
        elapsed=16.0, width=8,
    )
    # A quarter sent in 16 s: 64 KiB/s, and 3 MiB left is 48 s more.
    assert line == (
        "pushing [##------] 1000/4000 sources  1024/4096 KiB  64 KiB/s  eta 0:48"
    )


def test_push_progress_line_survives_a_stalled_start():
    """No throughput yet must not divide by zero or invent an ETA."""
    line = suite._format_push_progress(
        done=0, total=10, sent=0, total_bytes=1024, elapsed=0.0, width=4,
    )
    assert line == "pushing [----] 0/10 sources  0/1 KiB  0 KiB/s  eta --:--"


def test_progress_lines_redraw_in_place_only_on_a_terminal(monkeypatch, capsys):
    monkeypatch.setattr(suite, "_manifest_progress_line_open", [False])
    monkeypatch.setattr(sys.stdout, "isatty", lambda: False, raising=False)

    suite._manifest_progress("pushing 1/2", transient=True)
    suite._manifest_progress("done")

    # Piped (the remote runner): ordinary lines, no carriage returns to make a
    # log unreadable.
    output = capsys.readouterr().out
    assert "\r" not in output
    assert output.splitlines() == ["  manifest: pushing 1/2", "  manifest: done"]


def test_a_terminal_progress_line_is_closed_before_the_next_message(monkeypatch, capsys):
    monkeypatch.setattr(suite, "_manifest_progress_line_open", [False])
    monkeypatch.setattr(sys.stdout, "isatty", lambda: True, raising=False)

    suite._manifest_progress("pushing 1/2", transient=True)
    suite._manifest_progress("done")

    output = capsys.readouterr().out
    assert output.startswith("\r  manifest: pushing 1/2")
    # The in-place line gets its own newline so "done" does not land on top.
    assert output.endswith("\n  manifest: done\n")


def test_a_plain_run_pushes_the_corpus():
    """No environment at all must still establish the sources, not discover them."""
    assert suite.source_manifest_bootstrap_flags({}) == (False, False, True)


def test_asking_for_another_bootstrap_stands_the_push_down():
    trust = suite.source_manifest_bootstrap_flags(
        {"YASOS_SMOKE_SOURCE_MANIFEST_TRUST": "1"}
    )
    check = suite.source_manifest_bootstrap_flags(
        {"YASOS_SMOKE_SOURCE_MANIFEST_CHECK": "1"}
    )
    assert trust == (True, False, False)
    assert check == (False, True, False)


def test_an_explicit_push_setting_wins_over_the_default_and_the_other_modes():
    off = suite.source_manifest_bootstrap_flags(
        {"YASOS_SMOKE_SOURCE_MANIFEST_PUSH": "0"}
    )
    on = suite.source_manifest_bootstrap_flags({
        "YASOS_SMOKE_SOURCE_MANIFEST_PUSH": "1",
        "YASOS_SMOKE_SOURCE_MANIFEST_CHECK": "1",
    })
    # PUSH=0 asks for the lazy path -- no bootstrap at all, not a fallback to one
    # of the others.
    assert off == (False, False, False)
    assert on == (False, True, True)


def test_push_uploads_only_what_the_device_is_not_known_to_hold(
    push_mode, manifest, tmp_path
):
    _, entries = _manifest_case(tmp_path)
    _write_manifest(manifest.path, entries)
    manifest.corpus.update(entries)
    grown = {suite.remote_source_path(f"grown_{i}.c"): f"{i:064x}" for i in range(3)}
    manifest.corpus.update(grown)
    session = FakeSession([
        [suite._source_manifest_digest(entries)],  # the token read
        [],                                        # the token write
    ])

    suite.ensure_source_manifest_seeded(session)

    assert push_mode.pushed == sorted(grown)
    assert session.confirmed_uploads == manifest.corpus
    assert json.loads(manifest.path.read_text())["entries"] == manifest.corpus


def test_push_uploads_the_whole_corpus_when_the_device_witnesses_nothing(
    push_mode, manifest, tmp_path
):
    _, entries = _manifest_case(tmp_path)
    manifest.corpus.update(entries)
    manifest.corpus[suite.remote_source_path("second.c")] = "d" * 64
    session = FakeSession([[]])  # no map to read a token for, just the write

    suite.ensure_source_manifest_seeded(session)

    assert push_mode.pushed == sorted(manifest.corpus)
    assert session.confirmed_uploads == manifest.corpus


def test_push_reuses_a_matching_map_without_transferring_anything(
    push_mode, manifest, tmp_path
):
    _, entries = _manifest_case(tmp_path)
    _write_manifest(manifest.path, entries)
    manifest.corpus.update(entries)
    session = FakeSession([[suite._source_manifest_digest(entries)]])

    suite.ensure_source_manifest_seeded(session)

    assert push_mode.pushed == []
    assert session.confirmed_uploads == entries


def test_push_falls_back_to_per_test_verification_when_the_transfer_fails(
    push_mode, manifest, tmp_path, monkeypatch
):
    _, entries = _manifest_case(tmp_path)
    manifest.corpus.update(entries)

    def _failing_send(_session, _transfers, timeout=30.0, on_progress=None):
        raise TransferError("target went away mid-batch")

    monkeypatch.setattr(suite, "serial_send_files", _failing_send)
    session = FakeSession([])

    suite.ensure_source_manifest_seeded(session)

    # Nothing seeded, nothing written: the run carries on hashing per test.
    assert session.confirmed_uploads == {}
    assert not manifest.path.exists()


def test_source_manifest_rechecks_when_the_map_lost_most_of_the_corpus(
    manifest, tmp_path, monkeypatch
):
    _, entries = _manifest_case(tmp_path)
    _write_manifest(manifest.path, entries)
    manifest.corpus.update(entries)
    manifest.corpus.update(
        {suite.remote_source_path(f"grown_{i}.c"): f"{i:064x}" for i in range(4)}
    )
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_RECHECK_THRESHOLD", 2)
    monkeypatch.setattr(suite, "_verify_corpus_on_device", lambda _session, _corpus: dict(_corpus))
    session = FakeSession([[]])  # the token write, with no token read first

    suite.ensure_source_manifest_seeded(session)

    assert session.confirmed_uploads == manifest.corpus
    assert not any(command.startswith("cat ") for command in session.commands)


def test_source_manifest_tolerates_a_few_uncovered_sources(manifest, tmp_path, monkeypatch):
    _, entries = _manifest_case(tmp_path)
    _write_manifest(manifest.path, entries)
    manifest.corpus.update(entries)
    manifest.corpus[suite.remote_source_path("grown.c")] = "c" * 64
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_RECHECK_THRESHOLD", 2)

    def _unexpected_check(_session, _corpus):
        raise AssertionError("one uncovered source is not worth a corpus check")

    monkeypatch.setattr(suite, "_verify_corpus_on_device", _unexpected_check)
    session = FakeSession([[suite._source_manifest_digest(entries)]])

    suite.ensure_source_manifest_seeded(session)

    # The map is seeded as-is; the source it does not cover is verified by the
    # per-test path when a test reaches it.
    assert session.confirmed_uploads == entries


def test_source_manifest_verifies_per_file_when_device_token_is_stale(
    manifest, tmp_path, monkeypatch
):
    _, entries = _manifest_case(tmp_path)
    _write_manifest(manifest.path, entries)
    manifest.corpus.update(entries)
    monkeypatch.setattr(suite, "_verify_corpus_on_device", lambda _session, _corpus: {})
    session = FakeSession([["b" * 64]])

    suite.ensure_source_manifest_seeded(session)

    assert session.confirmed_uploads == {}


def test_source_manifest_reseeds_after_a_target_reset(manifest, tmp_path):
    _, entries = _manifest_case(tmp_path)
    _write_manifest(manifest.path, entries)
    manifest.corpus.update(entries)
    token = suite._source_manifest_digest(entries)
    session = FakeSession([[token], [token]])

    suite.ensure_source_manifest_seeded(session)
    # Session.reset_target() clears the cache and bumps the generation.
    session.confirmed_uploads.clear()
    session.confirmed_uploads_generation += 1
    suite.ensure_source_manifest_seeded(session)

    assert session.confirmed_uploads == entries
    assert not session._responses


def test_source_manifest_flush_records_host_map_and_device_token(manifest):
    entries = {suite.remote_source_path("00_assignment.c"): "a" * 64}
    session = FakeSession([[]])
    session.confirmed_uploads.update(entries)

    assert suite.flush_source_manifest(session, force=True) is True

    document = json.loads(manifest.path.read_text())
    assert document == {"version": suite.SOURCE_MANIFEST_VERSION, "entries": entries}
    digest = suite._source_manifest_digest(entries)
    assert session.commands == [
        f"echo {shlex.quote(digest)} > {shlex.quote(suite.REMOTE_MANIFEST_ID_PATH)}"
    ]
    # Nothing new was verified, so re-flushing must not touch the device again.
    assert suite.flush_source_manifest(session, force=True) is False
    assert not session._responses


def test_source_manifest_flush_waits_for_enough_new_sources(manifest, monkeypatch):
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_FLUSH_EVERY", 2)
    session = FakeSession([[]])
    session.confirmed_uploads[suite.remote_source_path("a.c")] = "a" * 64

    assert suite.flush_source_manifest(session) is False
    assert not manifest.path.exists()

    session.confirmed_uploads[suite.remote_source_path("b.c")] = "b" * 64

    assert suite.flush_source_manifest(session) is True


def test_source_manifest_written_by_a_flush_seeds_the_next_session(manifest, tmp_path):
    _, entries = _manifest_case(tmp_path)
    writer = FakeSession([[]])
    writer.confirmed_uploads.update(entries)
    suite.flush_source_manifest(writer, force=True)

    digest = writer.commands[0].split()[1]
    reader = FakeSession([[digest]])
    suite._source_manifest_state.update(generation=None, digest=None, count=0)
    suite.ensure_source_manifest_seeded(reader)

    assert reader.confirmed_uploads == entries


def test_upload_test_sources_stops_hashing_on_the_device_on_the_next_run(
    manifest, tmp_path, monkeypatch
):
    monkeypatch.setattr(suite, "SOURCE_MANIFEST_FLUSH_EVERY", 1)
    # Cold start with a device that fails the corpus check, so this run has to
    # fall back to per-file verification -- the worst case for the next run.
    monkeypatch.setattr(suite, "_verify_corpus_on_device", lambda _session, _corpus: {})
    source_dir = tmp_path / "sources"
    source_dir.mkdir()
    (source_dir / "manifest_case.c").write_text("int main(void) { return 0; }\n")
    testcase = suite.TccTestCase(
        test_id="manifest_case.c",
        name="manifest_case.c",
        sources=("manifest_case.c",),
        source_dir=source_dir,
    )
    remote_path = suite.remote_source_path("manifest_case.c", source_dir)
    digest = suite.sha256_file(str(source_dir / "manifest_case.c"))
    manifest.corpus[remote_path] = digest

    hashed = []

    def _device_hash(path, _session):
        hashed.append(path)
        return digest

    monkeypatch.setattr(suite, "get_remote_hash", _device_hash)

    first = FakeSession([[]])  # the manifest write
    assert suite.upload_test_sources(testcase, first) == "cached"
    assert hashed == [remote_path]

    # A later run: fresh process state, fresh session, same device.
    token = first.commands[0].split()[1]
    suite._source_manifest_state.update(generation=None, digest=None, count=0)
    second = FakeSession([[token]])
    assert suite.upload_test_sources(testcase, second) == "cached"

    assert hashed == [remote_path]  # no second device-side sha256sum
    assert second.commands == ["cat " + shlex.quote(suite.REMOTE_MANIFEST_ID_PATH)]


def test_manifest_is_recorded_when_the_pytest_session_finishes(manifest, monkeypatch):
    from smoke import conftest as smoke_conftest
    from smoke.framework.session import Session

    session = FakeSession([[]])
    session.confirmed_uploads[suite.remote_source_path("00_assignment.c")] = "a" * 64
    session._try_recover_prompt = lambda: True
    session.close = lambda: None
    monkeypatch.setattr(Session, "detached", classmethod(lambda cls, name: session))
    monkeypatch.setattr(Session, "target_crashed", False)
    monkeypatch.setattr(Session, "target_needs_reset", False)

    smoke_conftest._record_source_manifest()

    assert manifest.path.exists()


def test_manifest_is_not_recorded_when_the_target_is_wedged(manifest, monkeypatch):
    from smoke import conftest as smoke_conftest
    from smoke.framework.session import Session

    def _unexpected(cls, name):
        raise AssertionError("a crashed target must not be driven for the manifest")

    monkeypatch.setattr(Session, "detached", classmethod(_unexpected))
    monkeypatch.setattr(Session, "target_crashed", True)

    smoke_conftest._record_source_manifest()

    assert not manifest.path.exists()


def test_missing_input_diagnostic_drops_the_source_manifest(manifest):
    entries = {suite.remote_source_path("00_assignment.c"): "a" * 64}
    _write_manifest(manifest.path, entries)
    session = FakeSession([])
    session.confirmed_uploads.update(entries)

    suite.note_compile_failure_for_manifest(
        session,
        f"tcc: error: file '{suite.remote_source_path('00_assignment.c')}' not found",
    )

    assert session.confirmed_uploads == {}
    assert not manifest.path.exists()


def test_missing_include_of_a_confirmed_header_drops_the_source_manifest(manifest):
    entries = {suite.remote_source_path("builtins/chk.h", suite.gcc_execute_path): "a" * 64}
    _write_manifest(manifest.path, entries)
    session = FakeSession([])
    session.confirmed_uploads.update(entries)

    suite.note_compile_failure_for_manifest(
        session, "strcpy-chk.c:3: error: include file 'chk.h' not found"
    )

    assert session.confirmed_uploads == {}
    assert not manifest.path.exists()


def test_missing_include_we_never_uploaded_keeps_the_source_manifest(manifest):
    entries = {suite.remote_source_path("00_assignment.c"): "a" * 64}
    _write_manifest(manifest.path, entries)
    session = FakeSession([])
    session.confirmed_uploads.update(entries)

    # A header the upload scan never discovered is a harness gap, and blaming
    # the manifest for it would drop the manifest on every single run.
    suite.note_compile_failure_for_manifest(
        session, "00_assignment.c:1: error: include file 'undiscovered.h' not found"
    )

    assert session.confirmed_uploads == entries
    assert manifest.path.exists()


def test_ordinary_compile_error_keeps_the_source_manifest(manifest):
    entries = {suite.remote_source_path("00_assignment.c"): "a" * 64}
    _write_manifest(manifest.path, entries)
    session = FakeSession([])
    session.confirmed_uploads.update(entries)

    suite.note_compile_failure_for_manifest(
        session, "00_assignment.c:3: error: ';' expected"
    )

    assert session.confirmed_uploads == entries
    assert manifest.path.exists()


def test_gcc_conftest_get_opt_levels_defaults_to_both():
    assert suite._gcc_conftest.get_opt_levels(
        env_var="YASOS_TEST_OPT_LEVELS_UNSET",
        default=("-O0", "-O1"),
    ) == ["-O0", "-O1"]


def test_gcc_conftest_get_opt_levels_accepts_single_smoke_override(monkeypatch):
    monkeypatch.setenv("YASOS_SMOKE_TCC_OPT_LEVELS", "O1")

    assert suite._gcc_conftest.get_opt_levels(
        env_var="YASOS_SMOKE_TCC_OPT_LEVELS",
        default=("-O0",),
    ) == ["-O1"]
