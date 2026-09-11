"""
 Copyright (c) 2026 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 """

# On-chip supply and temperature: /proc/vreg and /proc/temp. Both are RP2350
# only; every other board publishes zeros, and these skip there.
#
# The regulator counters are reported, not asserted on: a low sample is a
# finding about the board's supply at this clock, not a kernel regression, and
# the value of the test is that the figures land in the run's log.

import time

import pytest

from .conftest import session_key


def read_fields(session, path):
    """Parse a `key value` /proc file into a dict of str -> int."""
    session.write_command(f"cat {path}")
    lines = session.wait_for_prompt_except_logs()

    values = {}
    for line in lines:
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            values[parts[0]] = int(parts[1])
        except ValueError:
            continue
    return values


def test_regulator_status_is_sampled(request):
    session = request.node.stash[session_key]
    before = read_fields(session, "/proc/vreg")
    assert "vreg_samples" in before, f"/proc/vreg did not parse: {before}"
    if before["vreg_setpoint_mv"] == 0:
        pytest.skip("target publishes no regulator status")

    time.sleep(0.5)
    after = read_fields(session, "/proc/vreg")

    # The system tick is the only sampler; a count that stands still means it
    # stopped, and every zero below would then be meaningless.
    assert after["vreg_samples"] > before["vreg_samples"], "the system tick stopped sampling VOUT_OK"

    request.node.user_properties.append(("vreg", after))
    print(
        f"vreg: setpoint {after['vreg_setpoint_mv']} mV "
        f"(VOUT_OK trips near {after['vreg_trip_nominal_mv']} mV), "
        f"{after['vreg_low_samples']} low of {after['vreg_samples']} samples "
        f"in {after['vreg_low_events']} sag(s), longest {after['vreg_low_max_run_ms']} ms, "
        f"last at {after['vreg_last_low_ms']} ms"
    )


def test_temperature_is_plausible(request):
    session = request.node.stash[session_key]
    fields = read_fields(session, "/proc/temp")
    assert "temp_mc" in fields, f"/proc/temp did not parse: {fields}"
    if fields["temp_samples"] == 0 and fields["temp_errors"] == 0:
        pytest.skip("target publishes no temperature sensor")

    assert fields["temp_errors"] == 0, f"ADC reported failed conversions: {fields}"
    # Wide on purpose: the sensor is uncalibrated, and an overclocked die runs
    # warm. What this catches is a wrong channel or a dead ADC, which read far
    # outside it.
    assert -20_000 < fields["temp_mc"] < 110_000, f"implausible die temperature: {fields}"

    request.node.user_properties.append(("temp_mc", fields["temp_mc"]))
    print(f"temp: {fields['temp_mc'] / 1000:.1f} C ({fields['temp_mv']} mV, raw {fields['temp_raw']})")
