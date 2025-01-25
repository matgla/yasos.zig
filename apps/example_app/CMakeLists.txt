#
# CMakeLists.txt
#
# Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version. This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>.
#

cmake_minimum_required(VERSION 3.28)

find_program(yaspem yaspem.py)

if (NOT yaspem OR $ENV{YASPEM_FETCH_FROM_GIT}})
  include(FetchContent)

  FetchContent_Declare(
    yaspem
    GIT_REPOSITORY https://github.com/matgla/Yaspem.git
    GIT_TAG master)

  FetchContent_MakeAvailable(yaspem)

else ()
  cmake_path(GET yaspem PARENT_PATH yaspem_dir)
  message(STATUS "Populating locally available Yaspem: ${yaspem_dir}")
  set (yaspem_SOURCE_DIR ${yaspem_dir})
endif ()
    
list (APPEND CMAKE_MODULE_PATH ${yaspem_SOURCE_DIR}/cmake) 
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(yaspem)

setup_yaspem(
  YASPEM_SOURCE ${yaspem_SOURCE_DIR} OUTPUT_DIRECTORY
  ${CMAKE_CURRENT_BINARY_DIR}/packages PACKAGE_FILES
  ${CMAKE_CURRENT_SOURCE_DIR}/packages.json)

find_package (CMakeUtils REQUIRED)

set (CMAKE_TOOLCHAIN_FILE ${CMakeUtils_SOURCE_DIR}/toolchains/arm-none-eabi-with-pic.cmake)

project(MspcSouthBridge ASM C CXX)

set(CMAKE_CPPFRONT_FLAGS "-fno-exceptions -fno-rtti" CACHE INTERNAL "")

set(CMAKE_INTERPROCEDURAL_OPTIMIZATION FALSE)
set(common_flags "-Werror -Wall -Wextra -Wconversion -Wno-unused -Wshadow -Wpointer-arith -Wcast-qual -Wdouble-promotion -Wno-missing-braces -Wno-analyzer-infinite-loop")
set(common_release_flags "") 
set(common_debug_flags "-g")

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fno-rtti -fno-exceptions -fmodules-ts -fno-threadsafe-statics -fno-module-lazy  ${common_flags}")

set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} ${common_release_flags}")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} ${common_debug_flags}")

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${common_flags}")
set(CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE} ${common_release_flags}")
set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} ${common_debug_flags}")

set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} ${common_flags}")
set(CMAKE_ASM_FLAGS_RELEASE "${CMAKE_ASM_FLAGS_RELEASE} ${common_release_flags}")
set(CMAKE_ASM_FLAGS_DEBUG "${CMAKE_ASM_FLAGS_DEBUG} ${common_debug_flags}")

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(hello_app)

target_sources(hello_app
  PRIVATE 
    main.cpp
)

find_package(Yasld REQUIRED)
list (APPEND CMAKE_MODULE_PATH ${Yasld_SOURCE_DIR}/cmake)

target_link_libraries(hello_app
  PRIVATE 
    yasld_executable_flags
)

include(ConvertElfToYasiff)

convert_elf_to_yasiff(
  TARGET hello_app 
  TYPE executable
)
