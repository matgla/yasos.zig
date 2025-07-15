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

from .conftest import session_key
import random

def test_compile_hello_world_with_usage_tracking(request):
    prevusage = None
    session = request.node.stash[session_key] 
    for i in range(10):
        session.write_command("tcc /usr/hello_world.c -o /tmp/hello")
        data = session.wait_for_prompt()
        usage = data.split("\n")[-2].split()[-1]
        if prevusage != None:
            assert prevusage == usage, "Memory usage should be the same after first file created in tmp"
        prevusage = usage   
        print(usage)
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
    

