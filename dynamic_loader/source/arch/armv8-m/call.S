//
// call.s
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//

.thumb
.syntax unified
.cpu cortex-m33

/*
r0 - int argc
r1 - char *argv[]
r2 - std::size_t main_address
r3 - std::size_t *got
*/

.global call_main
.thumb_func
.type call_main, %function
call_main:
  push {r4, lr}
  push {r0-r3}
  bl print_main_call
  pop {r0-r3}
  mov r4, r9
  push {r4, r5}
  mov r9, r3
  blx r2
  pop {r4, r5}
  mov r9, r4
  pop {r4, pc}


.global call_entry
.thumb_func
.type call_entry, %function
call_entry:
  push {r4, lr}
  mov r4, r9
  push {r4, r5}
  mov r9, r1
  blx r0
  pop {r4, r5}
  mov r9, r4
  pop {r4, pc}
