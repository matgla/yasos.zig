/**
 * main.c
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 *
 * This program is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation, either version
 * 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be
 * useful, but WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 * PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General
 * Public License along with this program. If not, see
 * <https://www.gnu.org/licenses/>.
 */

#include <stdio.h>
#include <setjmp.h>

jmp_buf jump_buffer;

void test_function() {
    printf("Inside test_function\n");
    longjmp(jump_buffer, 42);  // Jump back to where setjmp was called
}

int main() {
    int ret = setjmp(jump_buffer);

    if (ret == 0) {
        printf("First time through, ret = %d\n", ret);
        test_function();
    } else {
        printf("Returned via longjmp, ret = %d\n", ret);
    }

    return 0;
}