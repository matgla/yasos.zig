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

#include "utest.h"

#include <ctype.h>

UTEST(ctypes, isspace) {
  for (int c = 0; c < 256; ++c) {
    if (c != ' ' && c != '\t' && c != '\n' && c != '\v' && c != '\f' &&
        c != '\r') {
      ASSERT_FALSE(sut_isspace(c));
    } else {
      ASSERT_TRUE(sut_isspace(c));
    }
  }
}