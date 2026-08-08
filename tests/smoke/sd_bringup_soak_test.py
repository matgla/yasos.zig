"""SD card bring-up soak: how often does the card come up, and how does it fail?

Bring-up on this board is intermittent (see the SDIO notes in
``hal/source/raspberry/rp2350/source/mmc/``), and every attempt to attribute a
failure so far has been decided by one boot. One boot decides nothing here: the
same firmware has come up clean and failed within minutes of itself. This test
resets the target N times and classifies each boot, so a change can be argued
about with a rate.

Opt-in, like everything else that measures rather than asserts::

    scripts/remote_smoke_tui.py --pytest-args \\
        "tests/smoke/sd_bringup_soak_test.py -m measure -s"

``YASOS_SMOKE_SOAK_BOOTS`` sets the boot count (default 20). The runner forwards
no environment to remote pytest, so change the default here rather than
exporting it, or pass ``-k`` a copy.

Failure classes, which are different bugs and must not be pooled:

``acmd41``
    The card never reports itself powered up. The driver's own retry from CMD0
    (three attempts) has already been exhausted by the time this prints.

``bus_width``
    Bring-up got past ACMD41 and then every data read came back ``0xeeeeeeee``
    with a CRC error. That pattern is the diagnosis, not just a symptom: with
    DAT3..DAT0 read as one nibble, ``0xE`` is ``111x`` -- three lines idling
    high and one carrying data. It is what a 4-bit host reads from a card that
    is still in 1-bit mode, which is where the card is left when CMD55 or ACMD6
    is dropped during ``initialize_sdio_mmc``.

``no_mbr``
    The card answered but the MBR did not parse, with neither pattern above.

A run that is all ``ok`` proves nothing on its own either -- report the count.
"""

import os
import re

import pytest

from .conftest import session_key

pytestmark = pytest.mark.measure


DEFAULT_BOOTS = int(os.environ.get("YASOS_SMOKE_SOAK_BOOTS", "20"))

# The power-cycled variant is slower (uhubctl plus a serial re-enumeration per
# boot), so it runs fewer.
POWER_CYCLE_BOOTS = int(os.environ.get("YASOS_SMOKE_SOAK_POWER_BOOTS", "10"))

# The card is brought up before the shell exists, so the evidence is whatever
# the kernel printed between the reset and the first prompt.
_ACMD41_RE = re.compile(r"ACMD41 never ready|did not respond to ACMD41")
_BUS_WIDTH_RE = re.compile(r"0xeeeeeeee", re.IGNORECASE)
_NO_MBR_RE = re.compile(r"Invalid MBR found")
_CRC_RE = re.compile(r"checksum error|DataCrc")


def _classify(boot_text):
    if _ACMD41_RE.search(boot_text):
        return "acmd41"
    if _BUS_WIDTH_RE.search(boot_text):
        return "bus_width"
    if _NO_MBR_RE.search(boot_text):
        return "no_mbr"
    if _CRC_RE.search(boot_text):
        return "crc"
    return "ok"


def test_sd_bringup_soak(request):
    """Warm resets: the card stays powered and keeps whatever state it had."""
    _soak(request, DEFAULT_BOOTS, power_cycle=False)


def test_sd_bringup_soak_power_cycled(request):
    """Power cycles: the card comes up cold, with no state to inherit.

    Run this against the same firmware as the warm-reset soak. A firmware that
    is clean here and fails there is not miscommunicating with the card — it is
    leaving it somewhere the next bring-up cannot recover from, which is a
    different bug in a different place.
    """
    _soak(request, POWER_CYCLE_BOOTS, power_cycle=True)


def _soak(request, boots, power_cycle):
    session = request.node.stash[session_key]

    results = []
    for boot in range(boots):
        if power_cycle:
            session.power_reset_target()
        else:
            session.reset_target()
        # The banner and the whole storage bring-up land between the reset and
        # the first prompt, so one wait collects the evidence for this boot.
        #
        # `wait_for_data` and NOT `wait_for_prompt_except_logs`: the latter
        # drops every line starting with a log prefix, which is precisely the
        # evidence being classified here. It scored a run of boots as clean
        # while `DataCrc` was streaming past in the runner's own log tail.
        try:
            text = session.wait_for_data("$ ")
        except Exception as err:  # a boot that never reaches a prompt is a result
            text = f"no prompt: {err}"
        verdict = _classify(text)
        results.append(verdict)
        print(f"boot {boot + 1:>3}/{boots}: {verdict}")

    counts = {}
    for verdict in results:
        counts[verdict] = counts.get(verdict, 0) + 1

    ok = counts.get("ok", 0)
    print("\nSD bring-up soak over %d boots" % boots)
    for verdict in sorted(counts):
        print(f"  {verdict:<10} {counts[verdict]:>4}  ({100.0 * counts[verdict] / boots:5.1f}%)")
    print(f"  clean rate: {100.0 * ok / boots:.1f}%")
