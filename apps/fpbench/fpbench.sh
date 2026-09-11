# Run every floating point arm and print the comparison table.
#
#   sh /bin/fpbench.sh [iterations]
#
# Each arm records its own results under /tmp, so the last line joins whatever
# the four runs left behind -- including a run from a previous invocation, if
# one of the arms is missing from this rootfs.
fpbench-soft "$@"
fpbench-hwlib "$@"
fpbench-hwstatic "$@"
fpbench-inline "$@"
fpbench-inline --report
