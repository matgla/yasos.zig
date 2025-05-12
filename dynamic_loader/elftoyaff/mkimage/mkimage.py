#!/usr/bin/env python3
# -*- coding: utf-8 -*-

#
# mkimage.py
#
# Copyright (C) 2023 Mateusz Stadnik <matgla@live.com>
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

import argparse
import struct

from logger import LoggerSet, FileLogger, StdoutLogger

from colorama import Fore

from elf_parser import ElfParser
from relocation_set import RelocationSet
from enum import Enum

from pathlib import Path


class SectionCode(Enum):
    Code = 0
    Data = 1
    Init = 2
    Unknown = 3


def parse_cli_arguments():
    parser = argparse.ArgumentParser(
        description="""
                    MKImake converts ELF file to relocatable YASIFF modules.
                    It supports executables and libraries (WIP).
                    """
    )

    parser.add_argument(
        "-i",
        "--input",
        dest="input",
        action="store",
        help="Path to ELF file to be converted",
        required=True,
    )
    parser.add_argument(
        "-o",
        "--output",
        dest="output",
        action="store",
        help="Path to generated YASIFF",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        dest="verbose",
        action="store_true",
        help="Enable verbose mode",
    )
    parser.add_argument(
        "-q",
        "--quiet",
        dest="quiet",
        action="store_true",
        help="Disable stdout output",
    )
    parser.add_argument(
        "-s",
        "--libraries",
        nargs="*",
        action="store",
        help="Dependant shared libraries, necessary for i.e cortex-m0 where shared libraries must be build as executables. Separated by , or ;.",
    )
    parser.add_argument(
        "-d", "--dryrun", dest="dryrun", action="store_true", help="Dry run"
    )
    parser.add_argument(
        "-l", "--log", dest="log", action="store", help="Path to log file"
    )
    parser.add_argument(
        "-t",
        "--type",
        action="store",
        help="Type of module: library/executable. Workaround for Cortex-M0 to create shared libraries from executables",
    )

    args, _ = parser.parse_known_args()
    return args


class Application:
    def __init__(self, args):
        self.args = args
        self.logger = LoggerSet()
        self.logger.register_logger(StdoutLogger(self.args.verbose, self.args.quiet))
        if self.args.log:
            self.logger.register_logger(
                FileLogger(self.args.verbose, True, self.args.log)
            )
        if args.type:
            if args.type == "shared_library":
                self.is_executable = False
            else:
                self.is_executable = True

    def __print_header(self):
        self.logger.log(" ===========================================", Fore.YELLOW)
        self.logger.log("|    MKIMAGE - (ELF to YASIFF converter)    |", Fore.YELLOW)
        self.logger.log(" ===========================================", Fore.YELLOW)

    def __validate_section(self, section, position, name):
        if section == None:
            self.logger.error("Section '{}' not found!".format(name))
            self.logger.error("Existing sections: " + str(self.elf.sections.keys()))
            raise RuntimeError("Section validation failed")

        if section["address"] != position:
            self.logger.error(section["name"] + " is not placed at: " + hex(position))
            self.logger.error("Current address is: " + hex(section["address"]))
            raise RuntimeError("Section validation failed")

    def __has_section(self, name):
        if name in self.elf.sections:
            return True
        else:
            return False

    def __fetch_section(self, name, position, allow_failure=False):
        if name not in self.elf.sections:
            self.logger.info("Section '" + name + '" not found in ELF')
            return None
        section = self.elf.sections[name]
        if not allow_failure:
            self.__validate_section(section, position, name)
     
        self.logger.info("Found '" + name + "' with size: " + hex(section["size"]))
        return section

    def __fetch_sections(self):
        self.logger.info("Fetching sections")
        self.elf = ElfParser(self.args.input)
        self.text_section = self.__fetch_section(".text", 0x00000000)
        self.text = bytearray(self.text_section["data"])
        text_size = self.text_section["size"]
        
        # looks like tcc generates regular data in .rodata section sometimes, let's move rodata to .data for now
        # this requires to move .rodata section just before .data
        # or mkimage should be able to detect, if .rodata is after .text then we have read only rodata 
        # if just before .data then we have regular data 
        self.rodata_is_data = False
        if self.__has_section(".rodata"):
            self.rodata_section = self.__fetch_section(".rodata", self.text_section["size"], True)
            if self.rodata_section["address"] != self.text_section["size"]:
                self.rodata_is_data = True
            else:
                self.text += bytearray(self.rodata_section["data"])
                text_size += self.rodata_section["size"]

        # let's place init arrays in ram and fix addresses in yasld
        if self.__has_section(".init_arrays"):
            init_arrays_section_address = (
                self.text_section["address"] + text_size 
            )
            self.init_arrays_section = self.__fetch_section(
                ".init_arrays", init_arrays_section_address
            )
            self.init_arrays = bytearray(self.init_arrays_section["data"])
            plt_section_address = (
                self.init_arrays_section["address"] + self.init_arrays_section["size"]
            )
        else:
            self.init_arrays_section = None
            self.init_arrays = bytearray()
            plt_section_address = (
                self.text_section["address"] +  text_size
            )


        self.plt_address = plt_section_address 
        data_section_address = plt_section_address
        if self.__has_section(".plt"):
            self.plt_section = self.__fetch_section(".plt", self.plt_address)
            self.plt = bytearray(self.plt_section["data"])
            data_section_address += self.plt_section["size"]
        else:
            self.plt = bytearray()


        if self.rodata_is_data:
            self.data = bytearray(self.rodata_section["data"])
            self.data_section = self.__fetch_section(".data", data_section_address + self.rodata_section["size"])
            self.data += bytearray(self.data_section["data"])
        else:
            self.data_section = self.__fetch_section(".data", data_section_address)
            self.data = bytearray(self.data_section["data"])

        bss_section_address = self.data_section["address"] + self.data_section["size"]
        self.bss_section = self.__fetch_section(".bss", bss_section_address)
        self.bss = bytearray(self.bss_section["data"])


        self.got_section_address = bss_section_address + len(self.bss)

        if self.__has_section(".got"):
            self.got_section = self.__fetch_section(".got", self.got_section_address)
            self.got = bytearray(self.got_section["data"])
        else:
            self.got = bytearray()

        self.got_plt_address = self.got_section_address + len(self.got)
        if self.__has_section(".got.plt"):
            self.got_plt_section = self.__fetch_section(
                ".got.plt", self.got_plt_address
            )
            self.got_plt = bytearray(self.got_plt_section["data"])
        else:
            self.got_plt = bytearray()

        self.arm_extab_address = self.got_plt_address + len(self.got_plt)
        if self.__has_section(".ARM.extab"):
            self.arm_extab_section = self.__fetch_section(
                ".ARM.extab", self.arm_extab_address
            )
            self.arm_extab = bytearray(self.arm_extab_section["data"])
        else:
            self.arm_extab = bytearray()

        self.arm_exidx_address = self.arm_extab_address + len(self.arm_extab)
        if self.__has_section(".ARM.exidx"):
            self.arm_exidx_section = self.__fetch_section(
                ".ARM.exidx", self.arm_exidx_address
            )
            self.arm_exidx = bytearray(self.arm_exidx_section["data"])
        else:
            self.arm_exidx = bytearray()

    def __process_symbols(self):
        self.logger.info("Processing symbol table")
        self.symbols = {}

        self.main_is_entry = False

        if "main" in self.elf.symbols and self.elf.entry != None:
            self.main_is_entry = (self.elf.entry & 0xFFFFFFFE) == (
                self.elf.symbols["main"]["value"] & 0xFFFFFFFE
            )

        for name, data in self.elf.symbols.items():
            if not name or name == "$t" or name == "$d":
                continue

            if data["type"] == "STT_FILE":
                continue

            is_main = name == "main"

            if name in self.symbols:
                self.logger.error("Found duplicated symbol: " + name)
                raise RuntimeError("Symbols processing failed")

            # Fix undefined symbols
            is_global_and_visible = (
                data["binding"] == "STB_GLOBAL" or data["binding"] == "STB_WEAK"
            ) and data["visibility"] != "STV_HIDDEN"
            self.symbols[name] = data

            if is_global_and_visible or is_main:
                if data["section_index"] == "SHN_UNDEF":
                    self.symbols[name]["localization"] = "imported"
                else:
                    # only main can be exported in executable
                    if self.is_executable:
                        if is_main and self.main_is_entry:
                            self.symbols[name]["localization"] = "exported"
                        else:
                            self.symbols[name]["localization"] = "internal"
                    else:
                        self.symbols[name]["localization"] = "exported"
            else:
                self.symbols[name]["localization"] = "internal"

    def __print_symbol_table(self, visibility):
        symbols = dict(
            filter(lambda i: i[1]["localization"] == visibility, self.symbols.items())
        )

        if len(symbols) == 0:
            return

        self.logger.verbose(
            "+----------------------------- {:-<8s} ------------------------------+".format(
                visibility
            )
        )
        self.logger.verbose(
            "|                   name                   |    address   |    index     |"
        )
        self.logger.verbose(
            "+------------------------------------------+--------------+--------------|"
        )
        index = 0
        for symbol in symbols:
            self.logger.verbose(
                "| {: <40.40s} |  {: <10s}  |  {: <12d}   |".format(
                    symbol, hex(self.symbols[symbol]["value"]), index 
                )
            )
            index += 1

        self.logger.verbose(
            "+------------------------------------------+--------------+--------------|"
        )

    def __dump_symbol_table(self):
        if self.args.verbose:
            self.logger.verbose("Symbol table")
            self.__print_symbol_table("exported")
            self.__print_symbol_table("imported")
            self.__print_symbol_table("internal")

    def __process_relocations(self):
        self.logger.verbose("Processing relocation table")
        # Only GOT relocations must be processed, great description for relocation
        # is placed under ARM ABI: https://github.com/ARM-software/abi-aa/blob/main/aaelf32/aaelf32.rst
        # Or Android documentation: https://android.googlesource.com/toolchain/gdb/+/refs/heads/honeycomb/gdb-6.4/bfd/elf32-arm.c

        skipped_relocations = [
            "R_ARM_CALL",  # PC Relative
            "R_ARM_JUMP24",  # PC Relative
            "R_ARM_THM_JUMP24",
            "R_ARM_THM_CALL",  # PC Relative
            "R_ARM_ABS32",  # allowed for .data
            "R_ARM_PREL31",  # PC relative
            "R_ARM_TARGET1",  # relative for dynamic version
            "R_ARM_REL32",  # PC relative
            "R_ARM_NONE",  # can be ignored, just marker
            "R_ARM_THM_JUMP8",  # PC relative
            "R_ARM_THM_JUMP11",  # PC relative
            "R_ARM_RELATIVE",  # dynamic relocation
            # "R_ARM_JUMP_SLOT",  # TODO
            # "R_ARM_GLOB_DAT",
        ]

        self.relocations = RelocationSet()

        for relocation in self.elf.relocations:
            if relocation["info_type"] in skipped_relocations:
                continue
            elif relocation["info_type"] == "R_ARM_GOT_BREL":
                visibility = self.symbols[relocation["symbol_name"]]["localization"]
                if visibility == "internal":
                    self.relocations.add_local_relocation(relocation)
                else:
                    self.relocations.add_symbol_table_relocation(
                        relocation, self.got_section_address, visibility == "exported"
                    )
            elif relocation["info_type"] == "R_ARM_JUMP_SLOT":
                visibility = self.symbols[relocation["symbol_name"]]["localization"]
                self.relocations.add_symbol_table_relocation(
                    relocation, self.got_section_address, visibility == "exported"
                )
            elif relocation["info_type"] == "R_ARM_GLOB_DAT":
                visibility = self.symbols[relocation["symbol_name"]]["localization"]
                self.relocations.add_symbol_table_relocation(
                    relocation, self.got_section_address, visibility == "exported"
                )
            else:
                raise RuntimeError(
                    "Unknown relocation for '{name}': {relocation}".format(
                        name=relocation["symbol_name"],
                        relocation=relocation["info_type"],
                    )
                )

    def __process_data_relocations(self, init_offset, data_offset):
        self.logger.verbose(
            "Processing data relocations with init offset: "
            + hex(init_offset)
            + ", data offset: "
            + hex(data_offset)
        )

        skipped_relocations = [
            "R_ARM_CALL",  # PC Relative
            "R_ARM_JUMP24",  # PC Relative
            "R_ARM_GOT_BREL",  # GOT
            "R_ARM_THM_CALL",  # PC Relative
            "R_ARM_GLOB_DAT",
        ]

        for relocation in self.elf.relocations:
            if relocation["info_type"] in skipped_relocations:
                continue
            elif relocation["info_type"] == "R_ARM_ABS32":
                if relocation["symbol_name"] in self.symbols:
                    if self.elf.get_section_name(relocation["section_index"]) == None:
                        self.logger.error(
                            "Relocation '{}' towards unsupported sections: {}".format(
                                relocation["symbol_name"], relocation["section_index"]
                            )
                        )
                        raise RuntimeError("Data relocation processing failure")
                    from_address = int(relocation["offset"] - data_offset)
                    data = self.data
                    section_code = SectionCode.Data
                    offset = data_offset
                    if from_address < 0:
                        from_address = int(relocation["offset"] - init_offset)
                        if from_address < 0:
                            self.logger.error(
                                "Only .data and .init_arrays relocations are allowed, symbol '{}' relocation inside .text".format(
                                    relocation["symbol_name"]
                                )
                            )
                            self.logger.error(
                                "Original relocation offset: "
                                + hex(relocation["offset"])
                            )
                            raise RuntimeError("Data relocation processing failure")
                        data = self.init_arrays
                        section_code = SectionCode.Init
                        offset = init_offset
                    original_offset = struct.unpack_from("<I", data, from_address)[0]

                    if relocation["symbol_value"] < offset:
                        offset = original_offset << 2 | SectionCode.Code.value
                    else:
                        offset = ((original_offset - offset) << 2) | section_code.value

                    self.relocations.add_data_relocation(
                        relocation, from_address, offset
                    )
            elif relocation["info_type"] == "R_ARM_RELATIVE":
                from_address = int(relocation["offset"] - data_offset)

                data = self.data
                section_code = SectionCode.Data
                offset = data_offset
                original_offset = struct.unpack_from("<I", data, from_address)[0]

                if original_offset - offset < 0:
                    # this is a data relocation towards code
                    offset = original_offset << 2 | SectionCode.Code.value
                else: 
                    offset = ((original_offset - offset) << 2) | section_code.value

                self.relocations.add_data_relocation(
                    relocation, from_address, offset
                )

    def __dump_local_relocations(self):
        self.logger.verbose("Dumping local relocations")
        rels = self.relocations.get_relocations("local")
        if len(rels) == 0:
            return

        self.logger.verbose(
            "+------------------------------------------+-------| local |--------------+-----------------+---------+"
        )
        self.logger.verbose(
            "|                   name                   |   lot   |       offset       |      value      | section |"
        )
        self.logger.verbose(
            "+------------------------------------------+---------+--------------------+-----------------+---------+"
        )

        for rel in rels:
            section = self.elf.get_section_name(rel["section"])
            if section is None:
                section = "none"
            self.logger.verbose(
                "| {: <40s} | {: <7} | {: <18} | {: <15} | {: <7s} |".format(
                    rel["name"],
                    rel["index"],
                    hex(rel["offset"]),
                    hex(rel["symbol_value"]),
                    section,
                )
            )
        self.logger.verbose(
            "+------------------------------------------+---------+--------------------+-----------------+---------+"
        )

    def __dump_symbol_table_relocations(self):
        self.logger.step("Dumping symbol table relocations")
        rels = self.relocations.get_relocations("symbol_table")
        if len(rels) == 0:
            return

        self.logger.verbose(
            "+----------------------------------------| symbol table |-----------------+-----------------+"
        )

        self.logger.verbose(
            "|                   name                   |   lot   |       offset       |      value      |"
        )
        self.logger.verbose(
            "+------------------------------------------+---------+--------------------+-----------------+"
        )

        for rel in rels:
            self.logger.verbose(
                "| {: <40} | {: <7} | {: <18} | {: <15} |".format(
                    rel["name"],
                    rel["index"],
                    hex(rel["offset"]),
                    hex(rel["symbol_value"]),
                )
            )
        self.logger.verbose(
            "+------------------------------------------+---------+--------------------+-----------------+"
        )

    def __dump_data_relocations(self):
        self.logger.step("Dumping data relocations")
        rels = self.relocations.get_relocations("data")
        if len(rels) == 0:
            return

        self.logger.verbose(
            "+------------------------------------------|  data   |--------+------------------+-----------+"
        )
        self.logger.verbose(
            "|                   name                   |    from offset   |     to offset    |  section  |"
        )
        self.logger.verbose(
            "+------------------------------------------+------------------+------------------+-----------+"
        )

        for rel in rels:
            section = rel["offset"] & 0x3
            if section == 1:
                section = ".data"
            elif section == 2:
                section = ".init_arrays"
            else:
                section = ".text"
            from_offset = rel["offset"] >> 2

            name = rel["name"]
            if name == None:
                name = "-local-"
            self.logger.verbose(
                "| {: <40} | {: <16} | {: <16} | {: <9} |".format(
                    name, hex(from_offset), hex(rel["index"]), section
                )
            )

        self.logger.verbose(
            "+------------------------------------------+----------------+--------------------+-----------+"
        )

    def __dump_relocations(self):
        self.__dump_local_relocations()
        self.__dump_symbol_table_relocations()
        self.__dump_data_relocations()

    def __process_elf_file(self):
        self.logger.step("Processing ELF file: " + self.args.input)
        self.__fetch_sections()
        self.__process_symbols()
        self.__dump_symbol_table()
        self.__process_relocations()
        if self.init_arrays_section:
            init_offset = self.init_arrays_section["address"]
        else:
            init_offset = 0

        data_start = self.data_section["address"]
        if self.rodata_is_data:
            data_start = self.rodata_section["address"]

        self.__process_data_relocations(
            init_offset, 
            data_start,
        )
        self.__dump_relocations()

    def __fix_offsets_in_code(self):
        self.logger.step("Fixing offsets in code section")
        self.logger.verbose(
            "+------- at --------+------ from -------+------- to --------+------ symbol --------+"
        )

        for rel in self.relocations.relocations:
            if rel["type"] == "data":
                continue

            data_base = self.text
            relative_offset = rel["offset"]
            if rel["offset"] > len(self.text):
                if rel["offset"] > len(self.text) + len(self.init_arrays) + len(
                    self.data
                ):
                    data_base = self.bss
                    relative_offset = (
                        rel["offset"]
                        - len(self.text)
                        - len(self.data)
                        - len(self.init_arrays)
                    )
                elif rel["offset"] > len(self.text) + len(self.init_arrays):
                    data_base = self.data
                    relative_offset = (
                        rel["offset"] - len(self.text) - len(self.init_arrays)
                    )
                else:
                    data_base = self.init_arrays
                    relative_offset = rel["offset"] - len(self.text)
            try:
                old = struct.unpack_from("<I", data_base, relative_offset)[0]
            except struct.error as err:
                self.logger.error(
                    "Failure for symbol {} with offset {}, section: {}".format(
                        rel["name"],
                        hex(rel["offset"]),
                        self.elf.get_section_name(rel["section"]),
                    )
                )
                raise err

            new = rel["index"] * 4
            struct.pack_into("<I", data_base, relative_offset, new)
            self.logger.verbose(
                "| {: <17} | {: <17} | {: <17} | {}".format(
                    hex(rel["offset"]), hex(old), hex(new), rel["name"]
                )
            )

        for rel in self.relocations.omitted_relocations:
            if rel["type"] == "data":
                continue

            data_base = self.text
            relative_offset = rel["offset"]

            if rel["offset"] > len(self.text):
                if rel["offset"] > len(self.text) + len(self.init_arrays) + len(
                    self.data
                ):
                    data_base = self.bss
                    relative_offset = (
                        rel["offset"]
                        - len(self.text)
                        - len(self.data)
                        - len(self.init_arrays)
                    )
                elif rel["offset"] > len(self.text) + len(self.init_arrays):
                    data_base = self.data
                    relative_offset = (
                        rel["offset"] - len(self.text) - len(self.init_arrays)
                    )
                else:
                    data_base = self.init_arrays
                    relative_offset = rel["offset"] - len(self.text)

            old = struct.unpack_from("<I", data_base, relative_offset)[0]
            new = rel["index"] * 4
            struct.pack_into("<I", data_base, relative_offset, new)
            self.logger.verbose(
                "| {: <17} | {: <17} | {: <17} | {}".format(
                    hex(rel["offset"]), hex(old), hex(new), rel["name"]
                )
            )

        self.logger.verbose(
            "+-------------------+-------------------+-------------------+"
        )

    def __get_symbol_section(self, symbol):
        index = symbol["section_index"]
        if index == self.text_section["index"]:
            return SectionCode.Code
        elif (
            self.init_arrays_section != None
            and index == self.init_arrays_section["index"]
        ):
            return SectionCode.Init
        elif index == self.data_section["index"] or index == self.bss_section["index"]:
            return SectionCode.Data
        return None

    def __get_relocation_section(self, relocation):
        index = relocation["section"]
        if index == self.text_section["index"]:
            return SectionCode.Code
        elif (
            self.init_arrays_section != None
            and index == self.init_arrays_section["index"]
        ):
            return SectionCode.Init
        elif index == self.data_section["index"] or index == self.bss_section["index"]:
            return SectionCode.Data

    def __build_symbol_tables(self):
        self.exported_symbol_table = []
        self.imported_symbol_table = []

        for symbol, data in self.symbols.items():
            visibility = data["localization"]
            if visibility == "exported":
                self.exported_symbol_table.append({
                    "section": self.__get_symbol_section(data),
                    "value": data["value"],
                    "name": symbol,
                })

            elif visibility == "imported":
                self.imported_symbol_table.append({
                    "section": self.__get_symbol_section(data),
                    "value": data["value"],
                    "name": symbol,
                })

    def __filter_relocations(self, visibility, skip_duplications):
        filtered = []
        processed = []

        for rel in self.relocations.get_relocations(visibility):
            if rel["name"] in processed and skip_duplications:
                continue
            filtered.append(rel)
            processed.append(rel["name"])
        return filtered

    @staticmethod
    def __align_bytes(data, alignment):
        if len(data) % alignment != 0:
            return data + bytearray(alignment - len(data) % alignment)
        return data

    def __build_binary_symbol_table_for(self, symbols):
        table = bytearray()
        for symbol in symbols:
            value = symbol["value"]
            if symbol["section"] == SectionCode.Data:
                value -= len(self.text) + len(self.init_arrays)
            elif symbol["section"] == SectionCode.Init:
                value -= len(self.text)
            # if undefined treat same as text
            section = symbol["section"].value if symbol["section"] is not None else 0
            value = value << 2 | section
            table += struct.pack("<I", value)
            table += Application.__align_bytes(
                bytearray(symbol["name"] + "\0", "ascii"), 4
            )

        return table

    def __build_binary_relocation_table(
        self,
        symbol_table_relocations,
        local_relocations,
        data_relocations,
        imported_symbol_table,
        exported_symbol_table,
    ):
        table = []

        for rel in symbol_table_relocations:
            symbol = None
            symbol_table_index = 0
            if rel["is_exported_symbol"] is False:
                for s in imported_symbol_table:
                    if s["name"] == rel["name"]:
                        symbol = s
                        break
                    else:
                        symbol_table_index += 1
            elif rel["is_exported_symbol"] is True:
                symbol_table_index = 0
                for s in exported_symbol_table:
                    if s["name"] == rel["name"]:
                        symbol = s
                        break
                    else:
                        symbol_table_index += 1

            if not symbol:
                raise RuntimeError(
                    "Symbol {} not found in symbol table.".format(rel["name"])
                )
            table.append({"index": rel["index"] << 1 | rel["is_exported_symbol"], "offset": symbol_table_index})

        for rel in local_relocations:
            section = self.__get_relocation_section(rel)
            value = rel["symbol_value"]

            if section == SectionCode.Init:
                value -= len(self.text)
            if section == SectionCode.Data:
                value -= len(self.text) + len(self.init_arrays)

            if section == SectionCode.Unknown or section is None:
                raise RuntimeError(
                    "Unknown section for symbol '{}'".format(rel["name"])
                )

            index_with_section = rel["index"] << 2 | section.value
            table.append({"index": index_with_section, "offset": value})

        for rel in data_relocations:
            table.append({"index": rel["index"], "offset": rel["offset"]})

        return table

    def __build_image(self):
        self.logger.step("Building Yasiff image")
        image = bytearray("YAFF", "ascii")
        alignment = 4

        if self.is_executable:
            module_type = 1
        else:
            module_type = 2

        image += struct.pack("<BHB", module_type, 1, 1)  # dummy values for now
        image += struct.pack(
            "<IIII",
            len(self.text),
            len(self.init_arrays),
            len(self.data),
            len(self.bss),
        )
        entry = 0xFFFFFFFF
        if not self.main_is_entry:
            entry = self.elf.entry
        image += struct.pack("<I", entry)
        image += struct.pack("<HBB", len(self.dependant_libraries), alignment, 0)
        image += struct.pack("<HH", 0, 0)

        symbol_table_relocations = self.__filter_relocations("symbol_table", True)
        local_relocations = self.__filter_relocations("local", False)
        data_relocations = self.__filter_relocations("data", False)

        image += struct.pack(
            "<HHHH",
            len(symbol_table_relocations),
            len(local_relocations),
            len(data_relocations),
            0,
        )

        exported_symbol_table = self.__build_binary_symbol_table_for(
            self.exported_symbol_table
        )

        imported_symbol_table = self.__build_binary_symbol_table_for(
            self.imported_symbol_table
        )

        relocations = self.__build_binary_relocation_table(
            symbol_table_relocations,
            local_relocations,
            data_relocations,
            self.imported_symbol_table,
            self.exported_symbol_table,
        )

        image += struct.pack(
            "<HH", len(self.exported_symbol_table), len(self.imported_symbol_table)
        )

        image += struct.pack(
            "<IIII", len(self.got), len(self.got_plt), len(self.plt), 0
        )

        image += struct.pack("<II", len(self.arm_extab), len(self.arm_exidx))

        image += Application.__align_bytes(
            bytearray(Path(self.args.input).stem + "\0", "ascii"), alignment
        )

        for lib in self.dependant_libraries:
            image += Application.__align_bytes(
                bytearray(lib + "\0", "ascii"), alignment
            )

        for rel in relocations:
            image += struct.pack("<II", rel["index"], rel["offset"])

        image += imported_symbol_table
        image += exported_symbol_table

        image = Application.__align_bytes(image, 16)
        image += self.text
        image += self.init_arrays
        image += self.data
        image += self.plt
        image += self.got
        image += self.got_plt
        image += self.arm_extab
        image += self.arm_exidx

        self.image = image
        if not self.args.dryrun:
            self.logger.info("Writing to: " + self.args.output)
            with open(self.args.output, "wb") as file:
                file.write(image)

    def __resolve_dependant_libraries(self):
        self.dependant_libraries = self.elf.libraries
        if args.libraries is not None:
            for line in args.libraries:
                self.dependant_libraries += line.replace(",", ";").split(";")

        self.logger.info("Module depends on:")
        for lib in self.dependant_libraries:
            self.logger.info("  - " + lib)

    def execute(self):
        self.__print_header()
        self.__process_elf_file()
        # self.__fix_offsets_in_code()
        self.__build_symbol_tables()
        self.__resolve_dependant_libraries()
        self.__build_image()


if __name__ == "__main__":
    args = parse_cli_arguments()
    app = Application(args)
    app.execute()
