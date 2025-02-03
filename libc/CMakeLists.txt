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

# This target reexports newlibc as a shared library with 
# system calls implemented to talk with yasos kernel

cmake_minimum_required(VERSION 3.20)

project (yasos_libc C CXX)

set (CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_library (c SHARED)

target_sources (c
  PRIVATE 
    syscalls.c
)

target_include_directories(c
  PUBLIC 
    ${PROJECT_SOURCE_DIR}/include
)


set_target_properties (c
  PROPERTIES LINK_DEPENDS ${linker_script})

target_link_libraries(c
  PRIVATE -Wl,--whole-archive libc.a -Wl,--no-whole-archive
  gcc supc++ 
)



target_include_directories(c PRIVATE ${PROJECT_SOURCE_DIR}/../source)

target_link_options (c PRIVATE 
  -Wl,--no-warn-rwx-segments
  -T${linker_script}
  -nodefaultlibs 
  -nostartfiles
  -nostdlib
  -u__cxa_begin_cleanup
  -u__cxa_pure_virtual
  -u__gnu_Unwind_Find_exidx

)
