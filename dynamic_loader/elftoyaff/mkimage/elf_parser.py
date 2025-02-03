# -*- coding: utf-8 -*-

#
# elf_parser.py
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

from elftools.elf.elffile import ELFFile
from elftools.elf.sections import SymbolTableSection
from elftools.elf.relocation import RelocationSection
from elftools.elf.descriptions import describe_reloc_type
from elftools.elf.dynamic import DynamicSection


class ElfParser:
    def __init__(self, filename):
        self.symbols = ElfParser._parse_symbols(filename)
        self.sections = ElfParser._parse_sections(filename)
        self.relocations = ElfParser._parse_relocations(filename)
        self.libraries = ElfParser._parse_needed_libraries(filename)
        self.filename = filename
        self.executable = None
        self.entry = None
        with open(filename, "rb") as file:
            elf = ELFFile(file)
            self.executable = elf.header["e_type"] == "ET_EXEC"
            self.entry = elf.header["e_entry"]

    @staticmethod
    def _parse_needed_libraries(filename):
        libraries = []
        with open(filename, "rb") as file:
            elf = ELFFile(file)
            for section in elf.iter_sections():
                if isinstance(section, DynamicSection):
                    for tag in section.iter_tags():
                        if tag["d_tag"] == "DT_NEEDED":
                            libraries.append(tag.needed) 
        return libraries 

 

    @staticmethod
    def _parse_symbols(filename):
        symbols = {}
        with open(filename, "rb") as file:
            elf = ELFFile(file)
            for section in elf.iter_sections():
                if not isinstance(section, SymbolTableSection):
                    continue

                for symbol in section.iter_symbols():
                
                    symbol_type = symbol["st_info"]["type"]
                    section_index = symbol["st_shndx"]

                    if symbol_type == "STT_SECTION":
                        name = elf.get_section(section_index).name
                    else:
                        name = symbol.name

                    data = {
                        "type": symbol_type,
                        "binding": symbol["st_info"]["bind"],
                        "name": name,
                        "value": symbol["st_value"],
                        "size": symbol["st_size"],
                        "section_index": section_index,
                        "visibility": symbol["st_other"]["visibility"],
                    }
                    symbols[name] = data
        return symbols

    @staticmethod
    def _parse_sections(filename):
        sections = {}
        with open(filename, "rb") as file:
            elf = ELFFile(file)
            for i, section in enumerate(elf.iter_sections()):
                data = {
                    "name": section.name,
                    "address": section["sh_addr"],
                    "type": section["sh_type"],
                    "size": section["sh_size"],
                    "data": section.data(),
                    "index": i,
                }
                sections[section.name] = data
        return sections

    @staticmethod
    def _parse_relocations(filename):
        relocations = []
        with open(filename, "rb") as file:
            elf = ELFFile(file)
            for section in elf.iter_sections():
                if not isinstance(section, RelocationSection):
                    continue
                symbols = elf.get_section(section["sh_link"])
                for relocation in section.iter_relocations():
                    if relocation["r_info_sym"] == 0:
                        continue

                    symbol = symbols.get_symbol(relocation["r_info_sym"])
                    if symbol["st_name"] == 0:
                        symbol_section = elf.get_section(symbol["st_shndx"])
                        symbol_name = symbol_section.name
                    else:
                        symbol_name = symbol.name

                    data = {
                        "offset": relocation["r_offset"],
                        "info": relocation["r_info"],
                        "info_type": describe_reloc_type(
                            relocation["r_info_type"], elf
                        ),
                        "symbol": relocation["r_info_sym"],
                        "symbol_name": symbol_name,
                        "symbol_value": symbol["st_value"],
                        "section_index": symbol["st_shndx"],
                    }
                    relocations.append(data)
        return relocations

    def is_executable(self):
        return self.executable

    def get_section_name(self, index):
        for section_name, data in self.sections.items():
            if data["index"] == index:
                return section_name
        return None
