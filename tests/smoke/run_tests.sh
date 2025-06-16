#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
cd $SCRIPT_DIR

pytest -W error -s

if [ $? -ne 0 ]; then
    echo "Tests failed"
    cd `pwd`
    exit 1
fi

cd `pwd`
 