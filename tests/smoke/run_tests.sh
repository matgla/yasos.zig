#!/bin/bash

SCRIPT_DIR=$(dirname "$(realpath "$0")")
REPO_ROOT=$(realpath "$SCRIPT_DIR/../..")

cd "$REPO_ROOT"

python3 -m venv venv
source venv/bin/activate
pip install -r "$REPO_ROOT/tests/smoke/requirements.txt"

cd "$SCRIPT_DIR"

SERIAL_DEVICE="$1" pytest -W error -s

if [ $? -ne 0 ]; then
    echo "Tests failed"
    cd `pwd`
    exit 1
fi

deactivate
cd `pwd`
