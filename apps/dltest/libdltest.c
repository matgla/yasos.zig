/*
 * libdltest.c -- the shared library apps/dltest opens.
 *
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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

/* A data symbol: dlsym gives its address, and every handle to this library
   sees the same copy. */
int dltest_counter = 5;

static int calls;

/* Touches nothing: works whatever r9 the caller left. */
int dltest_answer(void) { return 42; }

/* Reads and writes this library's globals through its GOT: right only when
   the pointer dlsym gave switches r9 to this library's GOT. */
int dltest_bump(void) {
  ++calls;
  return dltest_counter + calls;
}
