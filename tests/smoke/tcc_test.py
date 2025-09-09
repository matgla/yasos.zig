"""
 Copyright (c) 2025 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 """


from .conftest import session_key
import random

def parse_memory_stats(data):
    lines = data.splitlines()
    stats = {}
    for line in lines:
        if not ":" in line:
            continue
        if line.strip():
            line = line.split(":", 1)
            value_str = line[1].split()
            value = int(value_str[0])
            unit = value_str[1] if len(value_str) > 1 else ""
            unit = unit.lower()
            if unit == "kb":
                value *= 1024
            elif unit == "mb":
                value *= 1024 * 1024
            stats[line[0]] = value
    return stats

def test_compile_hello_world_with_usage_tracking(request):
    prevusage = None
    session = request.node.stash[session_key]
    for i in range(15):
        output_file = '/tmp/hello' if i < 10 else f'/tmp/hello_{i}'
        session.write_command("tcc /usr/hello_world.c -o " + output_file)
        data = session.wait_for_prompt()
        session.write_command("cat /proc/meminfo")
        usage = session.wait_for_prompt()
        stats = parse_memory_stats(usage)
        # if prevusage != None:
        #     if i < 10:
        #         assert prevusage == stats, "memory usage should not raise"
        #     else:
        #         assert stats["MemKernelUsed"] > prevusage["MemKernelUsed"], "kernel memory should raise when creating new files in ramdisk"
        #         assert stats["MemProcessUsed"] == prevusage["MemProcessUsed"], "process memory should not raise after compiling a file"

        prevusage = stats
        session.write_command("/tmp/hello")
        data = session.read_line_except_logs()
        assert "Hello, World!" in data
        data = session.read_line_except_logs()
        assert "This is a simple C program." in data
        number = str(random.randint(0, 200000))
        session.write_command(number)
        data = session.read_line_except_logs()
        assert "You entered: " + number in data
        data = session.wait_for_prompt()


