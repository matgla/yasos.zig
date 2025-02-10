#
# CMakeLists.txt
#
# Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
#
# This program is free software: you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation, either version
# 3 of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be
# useful, but WITHOUT ANY WARRANTY; without even the implied
# warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
# PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General
# Public License along with this program. If not, see
# <https://www.gnu.org/licenses/>.
#

cmake_minimum_required(VERSION 3.20)

project (yasos_shell C CXX)

add_executable (yasos_shell)

set(CMAKE_C_FLAGS "-fpie -mcpu=cortex-m33 -nodefaultlibs -nostdlib")
set(CMAKE_EXE_LINKER_FLAGS "-pie -nodefaultlibs -nostartfiles -nostdlib -z now")


target_sources (yasos_shell
  PRIVATE 
    main.c
)

target_link_directories (yasos_shell PRIVATE ${PROJECT_SOURCE_DIR}/../../libc/build)

target_link_libraries (yasos_shell
  PRIVATE 
    c
)

set (linker_script ${PROJECT_SOURCE_DIR}/../../dynamic_loader/elftoyaff/arch/arm-m/linker_script.ld)

set_target_properties (yasos_shell
  PROPERTIES LINK_DEPENDS ${linker_script})

target_link_options (yasos_shell PRIVATE 
  -Wl,--no-warn-rwx-segments
  -T${linker_script}
  -e main
  -nodefaultlibs 
  -nostartfiles
  -nostdlib
)
