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

project (yasos_pthread C)

set (CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_library (pthread SHARED)

target_sources (pthread
  PRIVATE 
    pthread.c
)

target_include_directories(pthread
  PUBLIC 
    ${PROJECT_SOURCE_DIR}/include
)

set_target_properties (pthread
  PROPERTIES LINK_DEPENDS ${linker_script})


target_include_directories(pthread PRIVATE ${PROJECT_SOURCE_DIR}/../../source/kernel)

target_compile_options(pthread PRIVATE 
  -fPIC
  -nostdinc
  -mno-pic-data-is-text-relative
)

target_link_options (pthread PRIVATE 
  -fPIC
  -nostdlib
)

install (
  TARGETS
    pthread 
)

install (
  DIRECTORY
    include/
  DESTINATION 
    usr/include 
)
