#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
cd $SCRIPT_DIR
source smoke_venv/bin/activate
pytest -W error -s

if [ $? -ne 0 ]; then
    echo "Tests failed"
    deactivate
    cd `pwd`
    exit 1
fi

deactivate
cd `pwd`
 