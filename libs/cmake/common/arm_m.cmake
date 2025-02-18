#
# arm_m.cmake
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

include (${CMAKE_CURRENT_LIST_DIR}/../../../dynamic_loader/elftoyaff/cmake/toolchains/yasld_toolchain.cmake)

set (CMAKE_C_FLAGS "-nodefaultlibs -nostdlib")
set (CMAKE_EXE_LINKER_FLAGS "-nodefaultlibs -nostartfiles -nostdlib")
set (CMAKE_C_FLAGS_RELEASE "-Os")

set (linker_script ${PROJECT_SOURCE_DIR}/../../dynamic_loader/elftoyaff/arch/arm-m/linker_script.ld)

