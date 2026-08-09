//
// yasld.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//

pub const Loader = @import("loader.zig").Loader;
pub const MachineProfile = @import("loader.zig").MachineProfile;
pub const ImageError = @import("loader.zig").ImageError;
pub const Architecture = @import("header.zig").Architecture;
pub const FloatAbi = @import("header.zig").FloatAbi;
pub const Features = @import("header.zig").Features;
pub const Executable = @import("executable.zig").Executable;
pub const Environment = @import("environment.zig").Environment;
pub const SymbolEntry = @import("module.zig").SymbolEntry;
pub const Module = @import("module.zig").Module;
pub const get_loader = @import("loader.zig").get_loader;
pub const loader_init = @import("loader.zig").init;
pub const loader_deinit = @import("loader.zig").deinit;
pub const set_load_map_logging = @import("loader.zig").set_load_map_logging;
// Temporary load-phase accounting; see load_profile.zig.
pub const load_profile = @import("load_profile.zig");
