#!/bin/bash

source venv/bin/activate

SCRIPT_DIR=$(dirname "$0")
cd $SCRIPT_DIR

SERIAL_DEVICE="$1" pytest -W error -s

if [ $? -ne 0 ]; then
    echo "Tests failed"
    cd `pwd`
    exit 1
fi

deactivate
cd `pwd`
 