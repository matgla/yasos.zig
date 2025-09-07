/*
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
 */

.thumb
.syntax unified
.cpu cortex-m33

.global indirect_call_thunk_template_start
.thumb_func
.type indirect_call_thunk_template_start, %function
indirect_call_thunk_template_start:
    ldr r9, r9_value
    ldr ip, original_function_address
    bx ip
    nop
r9_value: .word 0xffffffff
original_function_address: .word 0xffffffff

.global indirect_call_thunk_template_size
indirect_call_thunk_template_size: .word . - indirect_call_thunk_template_start
