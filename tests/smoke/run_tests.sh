#!/bin/bash

SCRIPT_DIR=$(dirname "$(realpath "$0")")
REPO_ROOT=$(realpath "$SCRIPT_DIR/../..")

cd "$REPO_ROOT"

python3 -m venv venv
source venv/bin/activate
pip install -r "$REPO_ROOT/tests/smoke/requirements.txt"

cd "$SCRIPT_DIR"

# -v rather than the default dot progress: without it pytest keeps a single line
# open for a whole module and only terminates it once the module is done, so
# every line-oriented reader (the CI log viewer, `tee`, remote_smoke_tui's ssh
# pipe) sees nothing for minutes at a time -- an on-device run looks hung until
# it finishes. -v gives one line per test, which is also what progress.py's
# RUNNING announcer needs to close a pending line while a slow test is still in
# flight. The [n/total] counter and per-test wall time come from conftest.py's
# pytest_report_teststatus.
#
# PYTHONUNBUFFERED because stdout here is a pipe, not a tty (podman without -t,
# then the CI runner), so the venv python would otherwise block-buffer anything
# pytest itself does not explicitly flush.
SERIAL_DEVICE="$1" PYTHONUNBUFFERED=1 pytest -W error -s -v "${@:2}"

if [ $? -ne 0 ]; then
    echo "Tests failed"
    cd `pwd`
    exit 1
fi

deactivate
cd `pwd`
