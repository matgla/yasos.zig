# CI rig tower: Pi 5 + two Pico Plus 2 lanes

`ci_rig.scad` is a parametric OpenSCAD model of an open-frame tower:

| tier | holds | tray |
|---|---|---|
| 0 | Raspberry Pi 5 with the Active Cooler | `base` (nut traps underneath) |
| 1 | lane A: Pimoroni Pico Plus 2 on a Pico VGA Demo Base | `lane` |
| 2 | lane B: the same | `lane` (print two) |
| 3 | power-switch module (relays) | `service` |
| top | two Raspberry Pi Debug Probes, LEDs visible | `lid` |

The Pi 5 and the VGA Demo Base are both 85 × 56 mm, so every tier has the same
outline: 111 × 91 mm, 141 mm tall. Each tray carries four corner posts up to the
next tray. Four M3 threaded rods run through all the posts, with nuts recessed in
the base and the lid. The frame is open on every side, so the Pi's USB-C, HDMI,
USB and Ethernet, the lanes' SD slots, audio jacks and VGA connectors, and the
boards' RUN buttons can all be reached. Cables run down a 12 mm channel behind the
boards: the probes' JST-SH leads, the lanes' USB plugs and the GPIO wires to the Pi.

```bash
cd hardware/ci_rig
for p in base lane service lid; do openscad -D "part=\"$p\"" -o $p.stl ci_rig.scad; done
openscad ci_rig.scad          # assembly with ghost boards
```

`enclosed = true` (the default) gives every tray outer walls, from its plate up
to the next tray, with vent slots and cut-outs for the connectors (`pi_cuts`,
`lane_cuts`). `enclosed = false` gives the open frame. `explode = 40` spreads the
tiers apart in the assembly view.

Print flat side down. PETG is best because the Pi tier gets warm; 3 walls and
20 % infill. The open frame needs no supports. With walls, the long connector
cut-outs (the Pi's front and right sides, the lanes' VGA side) have 45–58 mm
bridges over them. Either let the printer bridge them or turn on supports for
those cut-outs only.

## Assembly

The boards are screwed on from above, each before the tray above it goes on:

1. Press M2.5 heat-set inserts into all the standoffs with a soldering iron
   (Pi: 4 in the base, VGA bases: 4 per lane tray).
2. Put an M3 nut into each hex pocket under the base and screw the four rods in
   from above.
3. Screw the Pi 5 to the base with 4 × M2.5 × 6. The Active Cooler clips into its
   own holes, so all four mounting holes stay free.
4. Slide lane tray A down the rods. Screw on the VGA base with the Pico Plus 2
   already in it: the holes are in the corners, clear of the Pico and the VGA
   connector. Plug its power and JST leads in and lead them into the back channel.
5. Do the same for lane tray B, then the service tray with the relay module.
6. Put the lid on, put the probes in their cradles, and tighten 4 M3 nuts into
   the lid's hex pockets. Stick rubber feet over the base nuts.

To get at one tier later, undo the four lid nuts and lift the trays above it
off the rods. The cables stay plugged in, lying in the back channel.

## Measure before printing

These values come from photos or third-party listings, not from drawings. Check
them with calipers and fix the parameters at the top of the `.scad` file:

- `vga_holes`: the VGA Demo Base's corner holes. From Pimoroni's photo they are
  about 3.5 mm in from each edge (78 × 49 mm); the hole size is assumed to be M2.5.
- `probe`: the Debug Probe in its case. A review gives 37 × 31 × 10 mm.
- `h_lane`: from the VGA base PCB to the top of the JST-SH plugs on the Pico
  Plus 2, plus room for the cables to bend.
- `h_pi`: the height of your Pi 5's tallest part (USB stack or cooler), plus
  about 8 mm for the fan intake.
- `switch_holes`: your relay module's holes. Leave the list empty to get a slot
  field instead.

## Bill of materials

| qty | part |
|---|---|
| 1 base, 2 lane, 1 service, 1 lid | printed |
| 4 | M3 threaded rod, ≥ 141 mm (one 1 m rod cut to length) + 8 M3 nuts |
| 12 + module | M2.5 heat-set inserts (OD 3.5 mm) + M2.5 × 6 screws (`use_inserts=false` for self-tapping) |
| 4 | rubber feet, stuck over the base nut traps |
| 1 | 2-channel relay module that switches with a **3.3 V** input (see below) |
| 2 | short USB-A extensions (probe VBUS goes through the relay) |
| 2 | micro-USB power-only pigtails (switched 5 V into the VGA bases' USB POWER sockets) |
| 4 | Dupont jumpers, Pi header to relay inputs (+ 2 more for the optional RUN wires) |

## Power reset: why no hub

The Pi 5's onboard USB ports cannot be switched one at a time. Each of its four
root hubs claims per-port power switching, but the
[uhubctl README](https://github.com/mvp/uhubctl) says all four ports share one
VBUS switch. VBUS drops only when every port is off (`uhubctl -l 2 -a 0` and
`uhubctl -l 4 -a 0`). With two lanes, resetting lane A that way would also cut
lane B mid-run and both probes. That is acceptable for a single board, but not
for two lanes running in parallel.

So each lane gets its own power switch, driven by a Pi GPIO pin:

```
Pi header 5V (pin 2) ──┬── relay A (NC) ──┬── lane A VGA base USB POWER (micro-USB pigtail)
                       │                  └── probe A VBUS (red wire of a USB-A extension)
                       └── relay B (NC) ──┬── lane B VGA base USB POWER
                                          └── probe B VBUS
probe A / probe B data, GND ───────────────── Pi 5 USB ports (unchanged)
```

- **Use the NC contacts.** The coil is off when the Pi boots or is idle, so the
  boards stay powered. A reset energises the coil for about 1 s.
- **Switch the probe together with its board.** A powered probe that idles its
  UART TX high into an unpowered RP2350 can feed the chip through its I/O
  protection diodes. The chip then never fully powers down, which may be why
  only physically unplugging the board has fixed the flash-stall state. The
  existing uhubctl path cycles "probe + board" (`uhubctl_port = 1,2`) for the
  same reason.
- **Power each board from one source only.** The VGA base's USB POWER socket and
  the Pico Plus 2's USB-C both feed VSYS. If the Pico's USB-C is ever wired to
  the Pi for data (USB NCM networking), break that cable's VBUS too.
  Otherwise the Pi 5 port back-powers the board.
- **Relay inputs:** many cheap "5 V relay modules" have optocoupled, active-low
  inputs. A 3.3 V GPIO pin cannot turn their LED fully off, so the relay never
  releases. Buy a module specified for 3.3 V logic, or a high-level-trigger
  module with a transistor input.
- **Current:** the header's 5 V pins connect straight to the Pi's power supply
  (they bypass the USB current limiter). Two lanes plus two probes draw about
  0.3–0.4 A.

Suggested GPIO map:

| GPIO | header pin | function |
|---|---|---|
| 17 | 11 | relay A (high = lane A off) |
| 27 | 13 | relay B (high = lane B off) |
| 22 | 15 | optional: lane A RUN, open drain |
| 23 | 16 | optional: lane B RUN, open drain |

```bash
pinctrl set 17 op dh; sleep 1; pinctrl set 17 op dl     # power-cycle lane A
pinctrl set 22 op dl; sleep 0.1; pinctrl set 22 ip pn   # pulse lane A RUN (never drive it high)
```

The optional RUN wire goes to the RUN side of the VGA base's RUN button (Pico pin
30). It gives a hard reset without a power cycle, faster than going through SWD.
Drive it open drain only: a high output would back-power an unpowered board.

### Off-the-shelf alternative

[Yepkit YKUSH 3](https://www.yepkit.com/) hubs switch VBUS and the data lines on
each port, using `ykushcmd` and labgrid's `YKUSHPowerPort`. One board has three
ports, so two lanes (two probes and two boards) need two of them. They mount on
the service tier's slot field instead of the relay module. This avoids all
cable modification, but costs more (about €40–50 each). The Waveshare
USB-HUB-4U can go either way: on the rig it never really cut power.

## Software work for two lanes (not done yet)

- **Pick each probe by serial number.** `scripts/rig/boot_check.py` takes
  `glob('/dev/serial/by-id/*Debugprobe*-if01')[0]`, and `reflash.sh` /
  `boot_check.py` call openocd without `adapter serial`. With two probes they
  would grab whichever one enumerates first.
- **Add a lock, workdir and card tree per lane.** Today there is one board lock
  and `~/yasos_remote_smoke/workdir`.
- **Add a GPIO reset next to the uhubctl reset in `remote_smoke_tui.py`.** The
  reset is currently `uhubctl_cmd ... -a off` / `-a on`. The GPIO version needs a
  per-lane pin.
- **Split the CI jobs across lanes** (`hardware_selfhost`, `hardware_zig_kernel`
  and the smoke run), so each runs on whichever lane is free.
