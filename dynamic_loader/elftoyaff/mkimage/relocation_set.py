#!/usr/bin/env python3
# -*- coding: utf-8 -*-

#
# relocation_set.py
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


class RelocationSet:
    def __init__(self):
        self.relocations = []
        self.omitted_relocations = []
        self.index = 0

    def __get_relocation(self, name):
        for r in self.relocations:
            if name == r["name"]:
                return r
        return None

    def __create_index(self, relocation_name):
        rel = self.__get_relocation(relocation_name)
        if rel is not None:
            return rel["index"]
        index = self.index
        self.index += 1
        return index

    def add_local_relocation(self, relocation):
        self.relocations.append({
            "name": relocation["symbol_name"],
            "symbol_value": relocation["symbol_value"],
            "offset": relocation["offset"],
            "section": relocation["section_index"],
            "index": self.index,
            "type": "local",
        })
        self.index += 1

    def add_symbol_table_relocation(self, relocation, got_start, is_exported_symbol):
        if self.__get_relocation(relocation["symbol_name"]) != None:
            self.omitted_relocations.append({
                "name": relocation["symbol_name"],
                "offset": relocation["offset"],
                "index": self.__get_relocation(relocation["symbol_name"])["index"],
                "symbol_value": relocation["symbol_value"],
                "type": "symbol_table",
                "is_exported_symbol": is_exported_symbol,
            })
            return

        self.relocations.append({
            "name": relocation["symbol_name"],
            "offset": relocation["offset"],
            "index": int(
                (relocation["offset"] - got_start) / 4
            ),  # self.__create_index(relocation["symbol_name"]),
            "symbol_value": relocation["symbol_value"],
            "type": "symbol_table",
            "is_exported_symbol": is_exported_symbol,
        })

    def add_data_relocation(self, relocation, index, offset):
        self.relocations.append({
            "name": relocation["symbol_name"],
            "offset": offset,
            "symbol_value": relocation["symbol_value"],
            "type": "data",
            "index": int(index),
        })

    def get_relocations(self, relocation_type):
        relocs = []
        for data in self.relocations:
            if data["type"] == relocation_type:
                relocs.append(data)

        return relocs
