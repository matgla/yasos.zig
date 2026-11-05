"""Reset the board and check that its shell answers at the working baud rate."""
import glob, subprocess, sys, time, serial
s = serial.Serial(glob.glob('/dev/serial/by-id/*Debugprobe*-if01')[0], 3000000, timeout=0.2)
s.reset_input_buffer()
subprocess.run(['openocd','-f','interface/cmsis-dap.cfg','-f','target/rp2350-rescue.cfg','-c','adapter speed 5000','-c','init','-c','exit'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
r = subprocess.run(['openocd','-c','set USE_CORE 0','-f','interface/cmsis-dap.cfg','-f','target/rp2350.cfg','-c','adapter speed 8000','-c','init','-c','reset run','-c','exit'],
               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
print('reset rc', r.returncode)
if r.returncode: print(r.stdout[-700:]); sys.exit(4)
buf = b''
end = time.time() + 15
while time.time() < end:
    buf += s.read(4096)
print('--- boot log tail'); print(buf[-1500:].decode('latin1'))
s.write(b'\r\n'); time.sleep(0.5)
s.write(b'echo baud-ok-$((40+2)); uname -a; tcc -v; mount; df\r\n')
out = b''
end = time.time() + 6
while time.time() < end:
    out += s.read(4096)
print('--- shell'); print(out.decode('latin1'))
print('BAUD_OK' if b'baud-ok-42' in out else 'NO_MATCH')
s.close()
sys.exit(0 if b'baud-ok-42' in out else 3)
