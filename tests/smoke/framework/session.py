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
import datetime
import subprocess
import re
import logging

import serial
from .detect_serial_port import detect_probe_serial_port

current_dir = os.path.dirname(os.path.abspath(__file__)) + "/.."
logger = logging.getLogger(__name__)

class Session:
    serial_port = None
    serial = None
    target_needs_reset = True
    target_crashed = False
    file = None
    prompt = "$ "
    crash_markers = (
        "hardfault diagnostics:",
        "hard fault occured",
        "kernel has halted.",
    )

    def __init__(self, name):
        if Session.serial_port is None:
            serial_device = os.environ.get("SERIAL_DEVICE")

            if serial_device != None and len(serial_device.strip()) > 0:
                logger.info("Using serial port %s", serial_device)
                Session.serial_port = serial_device
            else:
                Session.serial_port = detect_probe_serial_port()
        if Session.serial_port is None:
            raise RuntimeError("No serial port found for the debug probe.")
        if Session.serial is None or not Session.serial.is_open:
            Session.serial = serial.Serial(Session.serial_port, 921600, timeout=10)
            Session.target_needs_reset = True
        self.serial = Session.serial
        os.makedirs("logs", exist_ok=True)
        log_file = name.split(':')[-1].split(' ')[0]
        date = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        log_file = f"logs/{log_file}_{date}.txt"
        self.file = open(log_file, 'w')
        self._prepare_target()

    def _record_serial_output(self, text):
        if not text:
            return
        self.file.write(text)
        self.file.flush()
        normalized = text.lower()
        if any(marker in normalized for marker in Session.crash_markers):
            Session.target_crashed = True
            Session.target_needs_reset = True

    def _read_until(self, marker, timeout=None):
        old_timeout = self.serial.timeout
        if timeout is not None:
            self.serial.timeout = timeout
        try:
            data = self.serial.read_until(marker.encode('utf-8'))
        finally:
            if timeout is not None:
                self.serial.timeout = old_timeout

        text = data.decode('utf-8', 'ignore')
        self._record_serial_output(text)
        return text

    def _drain_serial_buffer(self):
        if self.serial.in_waiting <= 0:
            return ""
        data = self.serial.read(self.serial.in_waiting)
        text = data.decode('utf-8', 'ignore')
        self._record_serial_output(text)
        return text

    def _try_recover_prompt(self):
        buffered = self._drain_serial_buffer()
        if Session.prompt in buffered:
            return True

        self.serial.write(b"\n")
        recovered = self._read_until(Session.prompt, timeout=2)
        return recovered.endswith(Session.prompt)

    def _prepare_target(self):
        if Session.target_needs_reset:
            self.serial.reset_input_buffer()
            self.reset_target()
            self.serial.reset_input_buffer()
            self.wait_for_prompt_except_logs()
            while self.serial.in_waiting > 0:
                self.wait_for_prompt_except_logs()
            Session.target_needs_reset = False
            Session.target_crashed = False
        elif not self._try_recover_prompt():
            self.file.write("Prompt recovery failed, resetting target.\n")
            self.file.flush()
            Session.target_needs_reset = True
            self.serial.reset_input_buffer()
            self.reset_target()
            self.serial.reset_input_buffer()
            self.wait_for_prompt_except_logs()
            while self.serial.in_waiting > 0:
                self.wait_for_prompt_except_logs()
            Session.target_needs_reset = False
            Session.target_crashed = False

        self.write_command("cd /")
        self.wait_for_prompt_except_logs()

    def wait_for_prompt(self):
        return self.wait_for_data("$ ")

    def wait_for_prompt_except_logs(self):
        while True:
            lines = self._read_until(Session.prompt)
            if not lines.endswith(Session.prompt):
                if Session.target_crashed:
                    raise RuntimeError("Target crashed while waiting for prompt")
                raise RuntimeError("Prompt not found on serial port: '$ '")
            response = lines[:-len(Session.prompt)]
            split_lines = response.splitlines()
            filtered_lines = []
            for line in split_lines:
                if line.startswith("[INF]") or line.startswith("[ERR]") or line.startswith("[WRN]"):
                    continue
                stripped = line.strip()
                if stripped:
                    filtered_lines.append(stripped)

            return filtered_lines

    def wait_for_data(self, data):
        line = self._read_until(data)
        line = line.strip()
        if not line.endswith(data.strip()):
            if Session.target_crashed:
                raise RuntimeError("Target crashed while waiting for serial data: '" + data + "'")
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
        line = self.serial.readline().decode('utf-8', 'ignore')
        self._record_serial_output(line)
        line = line.strip()
        return line


    def read_line_except(self, regex):
        while True:
            line = self.serial.readline().decode('utf-8', 'ignore')
            self._record_serial_output(line)
            line = line.strip()
            if not re.search(regex, line):
                return line
        return ""

    def read_line_except_logs(self):
         while True:
            line = self.serial.readline().decode('utf-8', 'ignore')
            self._record_serial_output(line)
            if line.startswith("[INF]") or line.startswith("[ERR]") or line.startswith("[WRN]"):
                continue
            return line.strip()

    def reset_target(self):
        self.file.write("Resetting target with command: " + current_dir + "/reset_target.sh\n")
        output = subprocess.run("./reset_target.sh", shell=True, cwd=current_dir, stderr=subprocess.STDOUT, stdout=subprocess.PIPE)
        if (output.returncode != 0):
            output = subprocess.run("./reset_target.sh", shell=True, cwd=current_dir, stderr=subprocess.STDOUT, stdout=subprocess.PIPE)
        self.file.write(output.stdout.decode('utf-8'))
        self.file.flush()

    def shutdown_target(self):
        if Session.target_needs_reset or Session.target_crashed:
            self.file.write("Skipping target shutdown because the target is not running cleanly.\n")
            self.file.flush()
            return
        if not self._try_recover_prompt():
            self.file.write("Skipping target shutdown because prompt recovery failed.\n")
            self.file.flush()
            return
        self.write_command("exit")
        data = self.wait_for_data("You can turn off your PC now!")
        assert not "Memory leaks detected" in data
        Session.target_needs_reset = True

    @classmethod
    def finalize(cls):
        if cls.serial is None:
            return

        os.makedirs("logs", exist_ok=True)
        date = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        log_file = f"logs/session_shutdown_{date}.txt"
        session = cls.__new__(cls)
        session.serial = cls.serial
        session.file = open(log_file, 'w')
        try:
            session.shutdown_target()
        finally:
            session.file.close()
            cls.serial.close()
            cls.serial = None
            cls.target_needs_reset = True
            cls.target_crashed = False


    def close(self):
        self.file.close()


