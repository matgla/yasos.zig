"""
 Copyright (c) 2025 Mateusz Stadnik

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 the Software, and to permit persons to whom the Software is furnished to do so,
 subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 """

import serial
import pytest
from pyocd.core.helpers import ConnectHelper
from .detect_serial_port import detect_probe_serial_port


class Session:
    serial_port = None 
    def __init__(self): 
        if Session.serial_port is None:
            Session.serial_port = detect_probe_serial_port()
        if Session.serial_port is None:
            raise RuntimeError("No serial port found for the debug probe.")
        self.serial = serial.Serial(Session.serial_port, 921600, timeout=10)
        self.serial.read_all()
        self.serial.flushOutput()
        self.reset_target()
        self.wait_for_prompt()
        while self.serial.inWaiting() > 0:
            self.wait_for_prompt()

    def wait_for_prompt(self):
        line = self.serial.read_until("$ ".encode('utf-8')).decode('utf-8').strip()
        if not line.endswith("$"):
            raise RuntimeError("Prompt not found after reset")

    def write_command(self, command):
        self.serial.write((command + '\n').encode('utf-8'))
        line = self.serial.readline().decode('utf-8').strip()
        assert command in line, f"expected command '{command}' not found in: {line}"

    def read_line(self):
        line = self.serial.readline().decode('utf-8').strip()
        return line
    
    def reset_target(self):
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

    def close(self):
        self.serial.close()

