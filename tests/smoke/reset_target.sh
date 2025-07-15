#!/bin/bash

openocd -f interface/cmsis-dap.cfg -f target/rp2350.cfg -c "init; reset run; exit ;"