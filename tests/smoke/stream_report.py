"""Per-case console transcript for a recorded smoke run (YASOS_SMOKE_STREAM=1).

This is the printing the legacy-comparison harness uses in yasos-legacy-tcc
(``scripts/run_legacy_smoke_remote.sh --stream``), ported here so both arms of
the tinycc comparison put the same thing on screen: a header naming the case,
the target's own transcript underneath it -- the command sent, the compiler's
output, the program's output -- and a verdict line coloured by result.

The transcript itself comes from ``framework/session.py``; this module is only
the per-case frame around it.  pytest's own per-test output is suppressed while
streaming (conftest's ``pytest_report_teststatus`` returns an empty word), so
these lines stand alone, and ``scripts/remote_smoke_tui.py --stream`` drops
``-v`` from the remote pytest for the same reason.
"""

import os
import sys

STREAM = os.environ.get("YASOS_SMOKE_STREAM", "") == "1"


# Colour is on when stdout is a terminal, or forced with YASOS_SMOKE_COLOR=1 --
# which is what the runner does, because the remote pytest's stdout is an ssh
# pipe and a recorded session is captured rather than watched on the rig.
# NO_COLOR wins, per the convention.
def _use_colour():
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("YASOS_SMOKE_COLOR") == "1":
        return True
    try:
        return sys.stdout.isatty()
    except Exception:
        return False


COLOUR = _use_colour()

GREEN, RED, YELLOW, BOLD, DIM, CYAN = "32", "31", "33", "1", "2", "36"


def _c(code, text):
    return f"\033[{code}m{text}\033[0m" if COLOUR else text


_index = 0
_faulted = []


def case_label(nodeid):
    """The parametrised case name: what is inside the outermost brackets.

    The gcc-torture ids nest a second pair for the -O level
    (``...[gcc_execute/20000112-1[-O0]]``), so exactly one trailing bracket
    comes off rather than every one.
    """
    if "[" not in nodeid:
        return nodeid
    label = nodeid.split("[", 1)[1]
    return label[:-1] if label.endswith("]") else label


def logstart(nodeid, total):
    """Name the case FIRST, so the transcript that follows is attributed to it."""
    global _index
    _index += 1
    print(f"\n{_c(BOLD, f'[{_index:4}/{total}]')} "
          f"{_c(CYAN, case_label(nodeid))}", flush=True)


def _verdict_line(verdict, colour, label, duration, fault):
    line = f"       {verdict}  {_c(colour, f'{label:<52}')} {_c(DIM, f'{duration:6.2f}s')}"
    if fault:
        line += "   " + _c(YELLOW, f"<<< {fault}")
    return line


def logreport(report):
    """One verdict line per case, repeating the name now that it has an outcome.

    The header above the transcript cannot know the result yet, so the name is
    printed twice: once to introduce the transcript, once coloured by verdict.
    """
    label = case_label(report.nodeid)
    fault = getattr(report, "target_fault", "")
    if report.when == "call":
        # A rerun (pytest-rerunfailures) reports a call that is neither passed
        # nor failed yet; the retry prints its own line underneath.
        if getattr(report, "outcome", "") == "rerun":
            print(_verdict_line(_c(YELLOW, "RTRY"), YELLOW, label,
                                report.duration, fault), flush=True)
            return
        if report.passed:
            print(_verdict_line(_c(GREEN, "PASS"), GREEN, label,
                                report.duration, fault), flush=True)
        elif report.skipped:
            print(_verdict_line(_c(YELLOW, "SKIP"), YELLOW, label,
                                report.duration, fault), flush=True)
        else:
            print(_verdict_line(_c(RED, "FAIL"), RED, label,
                                report.duration, fault), flush=True)
        if fault:
            _faulted.append((label, fault))
        return
    # Setup and teardown only speak up when they went wrong: a skip decided at
    # setup still owes the case a verdict line, and an error in either phase is
    # not a result the call report will ever print.
    if report.skipped and report.when == "setup":
        print(_verdict_line(_c(YELLOW, "SKIP"), YELLOW, label,
                            report.duration, fault), flush=True)
    elif report.failed:
        print(f"       {_c(RED, report.when.upper() + ' ERROR')}  "
              f"{label}", flush=True)


def terminal_summary(terminalreporter):
    if not _faulted:
        return
    terminalreporter.write_sep("=", f"target faults ({len(_faulted)})")
    for name, fault in _faulted:
        terminalreporter.write_line(f"  {_c(YELLOW, f'{name:<52}')} {fault}")
