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

def test_compile_hello_world_with_usage_tracking(request):
    session = request.node.stash[session_key]
    for i in range(10):
        output_file = '/tmp/hello' if i < 6 else f'/tmp/hello_{i}'
        # Start leak detection before second iteration to capture steady-state leaks
        if i == 1:
            session.write_command("cat /proc/leakstart")
            session.wait_for_prompt()
        session.write_command("tcc /usr/hello_world.c -o " + output_file)
        data = session.wait_for_prompt(timeout=5)
        # Dump leaks after second iteration
        if i == 1:
            session.write_command("cat /proc/leakdump")
            session.wait_for_prompt()

        session.write_command(output_file)
        data = session.read_line_except_logs()
        assert "Hello, World!" in data
        data = session.read_line_except_logs()
        assert "This is a simple C program." in data
        number = str(random.randint(0, 200000))
        session.write_command(number)
        data = session.read_line_except_logs()
        assert "You entered: " + number in data
        data = session.wait_for_prompt()

    # Six iterations share /tmp/hello, the last four get one binary each. In a
    # /tmp that holds about a dozen small files, that is not a footprint to
    # leave for whatever runs next.
    session.write_command("rm -f /tmp/hello /tmp/hello_*")
    session.wait_for_prompt()
