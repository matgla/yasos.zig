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

import os
import time 
import datetime

import serial
import pytest
from pyocd.core.helpers import ConnectHelper
from .detect_serial_port import detect_probe_serial_port


class Session:
    serial_port = None 
    file = None
    def __init__(self): 
        if Session.serial_port is None:
            Session.serial_port = detect_probe_serial_port()
        if Session.serial_port is None:
            raise RuntimeError("No serial port found for the debug probe.")
        self.serial = serial.Serial(Session.serial_port, 921600, timeout=10)
        self.serial.read_all()
        self.serial.flushOutput()
        os.makedirs("logs", exist_ok=True)
        log_file = os.environ.get('PYTEST_CURRENT_TEST').split(':')[-1].split(' ')[0]
        date = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        log_file = f"logs/{log_file}_{date}.txt"
        self.file = open(log_file, 'w') 
        self.reset_target()
        self.wait_for_prompt()
        while self.serial.inWaiting() > 0:
            self.wait_for_prompt()

    def wait_for_prompt(self):
        self.wait_for_data("$ ") 
        
    def wait_for_data(self, data):
        line = self.serial.read_until(data.encode('utf-8')).decode('utf-8')
        self.file.write(line)
        line = line.strip()
        if not line.endswith(data.strip()):
            raise RuntimeError("Prompt not found on serial port: '" + data + "'")       
        return line

    def write_command(self, command):
        self.serial.write((command + '\n').encode('utf-8'))
        line = self.serial.readline().decode('utf-8')
        self.file.write(line)
        line = line.strip()
        assert command in line, f"expected command '{command}' not found in: {line}"

    def read_line(self):
        line = self.serial.readline().decode('utf-8')
        self.file.write(line) 
        line = line.strip()
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
        self.write_command("exit")
        self.wait_for_data("Root process died") 
        if self.serial.inWaiting() > 0:
            self.file.write(self.serial.read_all().decode("utf-8"))
        self.serial.close()
        self.file.close()

