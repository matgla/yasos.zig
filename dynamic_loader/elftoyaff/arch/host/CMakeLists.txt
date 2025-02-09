#
# CMakeLists.txt
#
# Copyright (C) 2023 Mateusz Stadnik <matgla@live.com>
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>.
#

add_library(yasld_arch)

set(include_dir ${CMAKE_CURRENT_SOURCE_DIR}/include/yasld)
target_sources(
  yasld_arch
  PUBLIC ${include_dir}/arch.hpp
  PRIVATE call.cpp)

target_link_libraries(yasld_arch PRIVATE yasld_flags)

target_include_directories(yasld_arch
                           PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
