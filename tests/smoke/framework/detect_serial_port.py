import os

import serial
import serial.tools.list_ports

def allowed_probes_list():
    return [
        '2e8a:000c',  # Raspberry Pi Debugprobe on Pico (CMSIS-DAP)
    ]

def detect_probe_serial_port():
    """The debug probe's UART.

    On a rig with several boards (scripts/rig/boards.py), YASOS_PROBE_SERIAL names
    the probe of the board this run holds: only that probe's port is returned, so a
    re-detection after a power cycle never lands on the other board's UART.
    """
    wanted = (os.environ.get("YASOS_PROBE_SERIAL") or "").strip()
    if wanted:
        for port in serial.tools.list_ports.comports(include_links=False):
            if (port.serial_number or "") == wanted:
                return port.device
        return None

    # Imported lazily so QEMU-mode runs (which never probe hardware) don't
    # require libudev/pyudev to be installed.
    import pyudev

    ports = serial.tools.list_ports.comports(include_links=False)
    for port in ports :
        context = pyudev.Context()
        for device in context.list_devices(subsystem='tty'):
    #         print(f"Device: {device.device_node}, Vendor ID: {device.properties.get('DEVNAME')}, Model ID: {device.properties.get('DEVTYPE')}")
            if port.device != device.device_node:
                continue
            return port.device
    #         if device.properties['ID_VENDOR_ID'] == None:
    #             continue
    #         device_id = f"{device.properties['ID_VENDOR_ID']}:{device.properties['ID_MODEL_ID']}"
    #         if device_id in allowed_probes_list():
    #             return port.device
