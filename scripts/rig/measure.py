"""measure.py PAYLOAD delta|full PYDIR DEST, on the rig: send a tcc_selfhost.py payload to the
board and time the compile, with a line of wall clock for everything it prints."""
import sys
import time
from pathlib import Path

payload, mode, pydir, dest = sys.argv[1:5]
sys.path[:0] = [pydir, "scripts", "."]
from yasos_device import run, uart_send_manifest, uart_session  # noqa: E402

start = None


def ts(msg):
    now = time.time()
    print(f"{time.strftime('%H:%M:%S', time.localtime(now))} +{(now - start) if start else 0:8.1f}s {msg}", flush=True)


s = uart_session()
t0 = time.time()
uart_send_manifest(s, Path(payload), dest, full=mode == "full")
print(f"upload took {time.time() - t0:.0f} s", flush=True)
for cmd in ["uname -a", "tcc -v", 'grep -E "MemKernel|LoaderCache" /proc/meminfo', "date"]:
    run(s, cmd, silence=30, echo=False, on_line=ts)
start = time.time()
ts("MEASURE start")
try:
    rc = run(s, f"sh {dest}/selfhost.sh {dest} {dest}/work 2 1", silence=3600, echo=False, on_line=ts)
    ts(f"MEASURE selfhost rc={rc}")
    run(s, 'grep -E "MemKernel|LoaderCache|MemUsed" /proc/meminfo; date', silence=30, echo=False, on_line=ts)
    ts("MEASURE DONE")
except Exception as e:
    ts(f"MEASURE ERROR {e!r}")
    sys.exit(1)
finally:
    s.close()
sys.exit(rc)
