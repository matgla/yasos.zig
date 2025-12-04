#!/bin/bash

python3 -m venv venv
source venv/bin/activate
pwd 
ls
pip install -r requirements.txt

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
 