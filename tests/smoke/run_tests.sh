#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
cd $SCRIPT_DIR
source smoke_venv/bin/activate
pytest -W error -s
deactivate
cd `pwd`