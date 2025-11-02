// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

comptime {
    _ = @import("driverfs.zig");
    _ = @import("driverfs_iterator.zig");
    _ = @import("mmc/card_parser.zig");
    _ = @import("uart/uart_driver.zig");
    _ = @import("uart/uart_file.zig");
    _ = @import("mmc/mmc_file.zig");
    _ = @import("mmc/mmc_partition_file.zig");
    _ = @import("mmc/mmc_driver.zig");
    _ = @import("mmc/mmc_partition_driver.zig");
    _ = @import("mmc/mmc_io.zig");
    _ = @import("flash/flash_file.zig");
    _ = @import("flash/flash_driver.zig");
}
