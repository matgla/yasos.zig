#!/usr/bin/env python3
# -*- coding: utf-8 -*-

#
# logger.py
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

from colorama import Fore, Style


class LoggerSet:
    def __init__(self):
        self.loggers = []

    def register_logger(self, logger):
        self.loggers.append(logger)

    def verbose(self, text):
        for logger in self.loggers:
            logger.verbose(text)

    def info(self, text):
        for logger in self.loggers:
            logger.info(text)

    def log(self, text, color=None):
        for logger in self.loggers:
            logger.log(text, color)

    def error(self, text):
        for logger in self.loggers:
            logger.error(text)

    def step(self, text):
        for logger in self.loggers:
            logger.step(text)


class FileLogger:
    def __init__(self, verbose, disable, filepath):
        self.is_verbose = verbose
        self.disable = disable
        self.filepath = filepath

    def verbose(self, text):
        if self.is_verbose:
            self.log("  [VERBOSE] " + text)

    def info(self, text):
        self.log("  [INFO]    " + text)

    def log(self, text, color=None):
        if not self.disable:
            with open(self.filepath, "a+") as file:
                file.write(text)

    def error(self, text):
        self.log("  [ERROR]   " + text)

    def step(self, text):
        self.log("[STEP]   " + text)


class StdoutLogger:
    def __init__(self, verbose, disable):
        self.is_verbose = verbose
        self.disable = disable

    def verbose(self, text):
        if self.is_verbose:
            self.log(Fore.BLUE + "  [VERBOSE] " + Style.RESET_ALL + text)

    def info(self, text):
        self.log(Fore.GREEN + "  [INFO]    " + Style.RESET_ALL + text)

    def log(self, text, color=None):
        color_format = ""
        color_stop = ""
        if color:
            color_format = color
            color_stop = Style.RESET_ALL
        if not self.disable:
            print(color_format + text + color_stop)

    def error(self, text):
        self.log(Fore.RED + "  [ERROR]   " + Style.RESET_ALL + text)

    def step(self, text):
        self.log(Fore.CYAN + "[STEP]   " + Style.RESET_ALL + text)
