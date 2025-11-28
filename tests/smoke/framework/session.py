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
import subprocess
import re

import serial
from pyocd.core.helpers import ConnectHelper
from .detect_serial_port import detect_probe_serial_port

current_dir = os.path.dirname(os.path.abspath(__file__)) + "/.."

class Session:
    serial_port = None
    file = None
    def __init__(self, name):
        if Session.serial_port is None:
            serial_device = os.environ.get("SERIAL_DEVICE")

            if serial_device != None and len(serial_device.strip()) > 0:
                print("Setting serialport to:", serial_device)
                Session.serial_port = serial_device
            else:
                Session.serial_port = detect_probe_serial_port()
        if Session.serial_port is None:
            raise RuntimeError("No serial port found for the debug probe.")
        self.serial = serial.Serial(Session.serial_port, 921600, timeout=10)
        self.serial.read_all()
        self.serial.flushOutput()
        os.makedirs("logs", exist_ok=True)
        log_file = name.split(':')[-1].split(' ')[0]
        date = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        log_file = f"logs/{log_file}_{date}.txt"
        self.file = open(log_file, 'w')
        self.reset_target()
        self.wait_for_prompt()
        while self.serial.inWaiting() > 0:
            self.wait_for_prompt()

    def wait_for_prompt(self):
        return self.wait_for_data("$ ")

    def wait_for_prompt_except_logs(self):
        while True:
            lines = self.serial.read_until(b"$ ")
            self.file.write(lines.decode('utf-8', 'ignore'))
            self.file.flush()
            lines = lines.decode('utf-8').splitlines()
            filtered_lines = []
            for line in lines:
                if line.startswith("[INF]") or line.startswith("[ERR]") or line.startswith("[WRN]"):
                    continue
                filtered_lines.append(line.strip())

            return filtered_lines

    def wait_for_data(self, data):
        line = self.serial.read_until(data.encode('utf-8')).decode('utf-8')
        self.file.write(line)
        self.file.flush()
        line = line.strip()
        if not line.endswith(data.strip()):
            raise RuntimeError("Prompt not found on serial port: '" + data + "'")
        return line

    def read_until(self, data):
        return self.wait_for_data(data)

    def read_raw(self, size, timeout=3):
        old_timeout = self.serial.timeout
        self.serial.timeout = timeout
        data = self.serial.read(size)
        self.serial.timeout = old_timeout
        return data

    def read_until_prompt(self):
        return self.read_until("$")

    def write_raw(self, data, timeout):
        self.serial.write(data)

    def write_command(self, command):
        self.serial.write((command + '\n').encode('utf-8'))
        data = self.wait_for_data(command + '\n');
        line = data.strip()
        assert command in line, f"expected command '{command}' not found in: {line}"

    def read_line(self):
        line = self.serial.readline().decode('utf-8')
        self.file.write(line)
        self.file.flush()
        line = line.strip()
        return line


    def read_line_except(self, regex):
        while True:
            line = self.serial.readline().decode('utf-8')
            self.file.write(line)
            line = line.strip()
            self.file.flush()
            if not re.search(regex, line):
                return line
        return ""

    def read_line_except_logs(self):
         while True:
            line = self.serial.readline().decode('utf-8')
            self.file.write(line)
            if line.startswith("[INF]") or line.startswith("[ERR]") or line.startswith("[WRN]"):
                continue
            return line.strip()
            self.file.flush()

    def reset_target(self):
        self.file.write("Resetting target with command: " + current_dir + "/reset_target.sh\n")
        output = subprocess.run("./reset_target.sh", shell=True, cwd=current_dir, stderr=subprocess.STDOUT, stdout=subprocess.PIPE)
        if (output.returncode != 0):
            output = subprocess.run("./reset_target.sh", shell=True, cwd=current_dir, stderr=subprocess.STDOUT, stdout=subprocess.PIPE)
        self.file.write(output.stdout.decode('utf-8'))
        self.file.flush()


    def close(self):
        self.serial.close()
        self.file.close()


