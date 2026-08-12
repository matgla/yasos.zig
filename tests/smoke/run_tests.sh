#!/bin/bash

SCRIPT_DIR=$(dirname "$(realpath "$0")")
REPO_ROOT=$(realpath "$SCRIPT_DIR/../..")

cd "$REPO_ROOT"

python3 -m venv venv
source venv/bin/activate
pip install -r "$REPO_ROOT/tests/smoke/requirements.txt"

cd "$SCRIPT_DIR"

# -v rather than the default dot progress: without it pytest keeps one line open
# for a whole module, so every line-oriented reader (the CI log viewer, `tee`,
# remote_smoke_tui's ssh pipe) sees nothing for minutes and a run looks hung.
# The [n/total] counter and per-test wall time come from conftest.py.
#
# PYTHONUNBUFFERED because stdout here is a pipe, not a tty, so the venv python
# would otherwise block-buffer anything pytest does not explicitly flush.
SERIAL_DEVICE="$1" PYTHONUNBUFFERED=1 pytest -W error -s -v "${@:2}"

if [ $? -ne 0 ]; then
    echo "Tests failed"
    cd `pwd`
    exit 1
fi

deactivate
cd `pwd`
