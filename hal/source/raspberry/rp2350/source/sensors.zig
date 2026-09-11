//
// sensors.zig
//
// Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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

// On-chip supply and temperature readings: the core regulator's own
// in-regulation flag, and the temperature sensor on the ADC. Not behind the HAL
// interface for the same reason as `xip.zig` -- the kernel reaches both through
// provider hooks, so another board has nothing useful to stub.

/// POWMAN VREG_STS. VOUT_OK is live status, not a latch: it drops while the
/// core rail sits below ~87% of the VSEL setpoint (84-90% across parts) and
/// comes back once the rail recovers.
const powman_vreg_sts: *const volatile u32 = @ptrFromInt(0x40100008);
const vreg_sts_vout_ok: u32 = 1 << 4;

pub fn vreg_in_regulation() bool {
    return powman_vreg_sts.* & vreg_sts_vout_ok != 0;
}

const Adc = extern struct {
    cs: u32,
    result: u32,
};

const adc: *volatile Adc = @ptrFromInt(0x400a0000);

const adc_cs_en: u32 = 1 << 0;
const adc_cs_ts_en: u32 = 1 << 1;
const adc_cs_start_once: u32 = 1 << 2;
const adc_cs_ready: u32 = 1 << 8;
const adc_cs_err: u32 = 1 << 9;
const adc_cs_ainsel_lsb = 12;

// RESETS, written through the atomic-clear alias so no other block's reset bit
// is read-modify-written from here.
const resets_reset_clear: *volatile u32 = @ptrFromInt(0x40020000 + 0x3000);
const resets_reset_done: *const volatile u32 = @ptrFromInt(0x40020008);
const resets_adc: u32 = 1 << 0;

/// SYSINFO PACKAGE_SEL: 0 on the QFN-80 RP2350B, 1 on the QFN-60 RP2350A. The
/// SDK headers leave the encoding undocumented; 0 is what the pimoroni_pico_plus2
/// (an RP2350B) reads.
const sysinfo_package_sel: *const volatile u32 = @ptrFromInt(0x40000004);

/// Polls before a wait is abandoned. A conversion is 96 clk_adc cycles, 2 us at
/// 48 MHz; this bound is milliseconds at any clk_sys the board runs.
const poll_limit: u32 = 1_000_000;

/// The temperature sensor is the last ADC input, and AINSEL counts only the
/// channels the package bonds out: 4 on the RP2350A, 8 on the RP2350B.
fn temperature_channel() u32 {
    return if (sysinfo_package_sel.* & 1 != 0) 4 else 8;
}

fn wait_ready() bool {
    var polls: u32 = 0;
    while (adc.cs & adc_cs_ready == 0) : (polls += 1) {
        if (polls >= poll_limit) return false;
    }
    return true;
}

/// Take the ADC out of reset and power the temperature sensor. `crt_init`
/// leaves the ADC in reset; clk_adc already runs from PLL_USB at 48 MHz
/// (`runtime_init_clocks`), and nothing after that touches it.
pub fn enable_temperature_sensor() bool {
    resets_reset_clear.* = resets_adc;
    var polls: u32 = 0;
    while (resets_reset_done.* & resets_adc == 0) : (polls += 1) {
        if (polls >= poll_limit) return false;
    }
    adc.cs = adc_cs_en | adc_cs_ts_en;
    return wait_ready();
}

/// One conversion of the temperature sensor as the raw 12-bit code, or null
/// when the ADC flagged the conversion or never finished it. The caller
/// serialises: a conversion is select, start, poll, read, and two interleaved
/// callers would each take the other's result.
pub fn read_temperature_raw() ?u16 {
    adc.cs = adc_cs_en | adc_cs_ts_en | (temperature_channel() << adc_cs_ainsel_lsb);
    adc.cs = adc_cs_en | adc_cs_ts_en | (temperature_channel() << adc_cs_ainsel_lsb) | adc_cs_start_once;
    if (!wait_ready()) return null;
    if (adc.cs & adc_cs_err != 0) return null;
    return @intCast(adc.result & 0xfff);
}
