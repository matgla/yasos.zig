import serial
from pyocd.core.helpers import ConnectHelper

serial = serial.Serial('/dev/ttyACM0', 921600, timeout=10)

session = ConnectHelper.session_with_chosen_probe(options={
    "target_override": "rp2350",
})
if session is None:
    raise RuntimeError("No debug probe found.")
session.open()
try:
    session.target.reset()
finally:
    session.close()

line = serial.read_until("$".encode('utf-8')).decode('utf-8').strip()
print(line)

serial.write(b"ls\n")
print(serial.readline().decode('utf-8').strip())