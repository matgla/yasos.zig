# CI rig tower: Pi 5 + two Pico Plus 2 lanes

`ci_rig.scad` is a parametric OpenSCAD model of an open-frame tower:

| tier | holds | tray |
|---|---|---|
| 0 | Raspberry Pi 5 with the Active Cooler | `base` (nut traps underneath) |
| 1 | lane A: Pimoroni Pico Plus 2 on a Pico VGA Demo Base | `lane` |
| 2 | lane B: the same | `lane` (print two) |
| (3) | optional: reel tier (`extra_tier = "reels"`) or power-switch module (`"relays"`); default `"none"` | `service` |
| top | two Debug Probes lying along the long edge (`probe_rot`), diagonal (`probe_diag`): A in front on the right, turned round, B behind on the left, each snapped into a pocket on its own oval spool; walls and a roof enclose the top | `lid` + `roof` |

The Pi 5 and the VGA Demo Base are both 85 × 56 mm, so every tier has the same
outline: 111 × 99 mm (the spools keep 5 mm from the walls and from each other; 111 × 111 with `probe_diag = false`), about 160 mm tall. The lane trays have floor crossbars (`lane_bars`), but none across the 20 mm channel behind the board. The lid's floor is open in the same way (`lid_open_floor`), with a pad under each spool. Leads pass with their plugs on, and the JST slots are 6.5 × 10 mm. The walls carry the stack. In each corner
there is only a nut block at the top, on a 45° gusset into the corner, and a low
ring under the screw head at the bottom. Each tray is screwed to the tray below it
with M3 × 10 screws into nuts that slide into those blocks, 3 mm below their tops.
With `enclosed = false` the corners are full posts (`tier_join = "rods"` gives
four threaded rods through everything instead). The frame is open on every side, so the Pi's USB-C, HDMI,
USB and Ethernet, the lanes' SD slots, audio jacks and VGA connectors, and the
boards' RUN buttons can all be reached. Cables run down a 12 mm channel behind the
boards: the probes' JST-SH leads, the lanes' USB plugs and the GPIO wires to the Pi.

Sliced plates (PrusaSlicer, MK3S, Bambu PLA Matte, 0.25 mm) are in `print/`:
`1_base` (base), `1b_pi_clamps` (2 Pi clamps; print them once `pi_stack_h` is measured), `2_lanes` (2 lane trays), `3_lid_roof`
(lid with the probe spools, and the roof).

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

## Printing (PLA, 0.2 mm)

The base is a frame with ribs (`base_floor = "ring"`, the default), like the lane
trays, so air comes in from below. Each connector cut-out has a bridge over it:
a lintel 5 mm deep inside the wall, carried at both ends by pillars that stand on
the frame. PrusaSlicer prints it as bridge infill rather than wall hanging in the
air. The vents are 12 mm windows every 20 mm with 45° pointed tops, so they need no
bridge (`vent_w`, `vent_pitch`). The original 3 mm slots every 8 mm cost about
12 min per lane tray and 29 min on the lid, because every slot adds short
perimeters on every layer. On the 0.2 mm SPEED profile in PLA, with
the first layer at 2000 mm/s² instead of 500, the base takes 2 h 46 min. Most of
that is the walls (the open frame takes 1 h 42 min). 0.3 mm ULTRA takes 1 h 39 min,
but the surface is worse.

## Pi 5 on its own

`base` + `pi_top` make a case for the Pi 5 alone: the base tier with a flat cover
that has a grille over the Active Cooler. Four M3 × 35 socket-head screws go
through the cover and the posts into the nuts under the base. In the full tower,
lane tray A takes the cover's place.

## Assembly

The boards are screwed on from above, each before the tray above it goes on:

1. Default (`fastener = "tap"`): each standoff has a plain 2.2 mm hole from the
   top; an M2.5 screw cuts its own thread in the plastic. With `"nut"`, press an
   M2.5 nut into the hex pocket under each standoff; with `"insert"`, melt
   heat-set inserts into the standoff tops.
   Board screws are M2.5: the Pi 5's holes are 2.7 mm, too small for M3
   (`board_screw = 3` exists for a board with 3.2 mm holes).
2. Slide an M3 nut into the side slot near the top of each base post (the
   slots open toward the middle of the case).
3. The Pi carries a screwed-on heatsink and an NVMe HAT on standoffs, so it gets
   no screws of its own (`pi_fastener = "pocket"`). The screw heads or nuts
   already under its holes drop into pockets in the standoff tops, which stop it
   sliding. Two `pi_clamp` parts, shaped _|-|_, hold it down: each runs front to
   back along a line of holes, with pads pressing on the HAT's standoff screws,
   and is fixed with 2 × M3 × 10 self-tapping screws into the bosses on the base.
   Measure `pi_stack_top` (from the base floor top to the top of the HAT's screw
   heads; 26 mm is a guess) and print the clamps for it. They take minutes.
4. Set lane tray A on the base posts and fix it with 4 × M3 × 10: drop each
   screw down the tray's hollow post and turn it with a 2.5 mm hex key through
   the hole in the post top. Then slide the next nuts into the tray's own post
   slots. Screw on the VGA base with the Pico Plus 2
   already in it: the holes are in the corners, clear of the Pico and the VGA
   connector. Plug its power and JST leads in and lead them into the back channel.
5. Do the same for lane tray B, then the service tray with the relay module.
6. Screw the lid to the service tray's posts with 4 × M3 × 10 (the heads sit in
   counterbores) and put the probes in their cradles. Stick on rubber feet.

To get at one tier later, unscrew the tiers above it one by one, from the top. The cables stay plugged in, lying in the back channel.

## Cables

`cables.scad` draws the routes and echoes the lengths. It also checks them:
`openscad -D 'show="clash"' -D 'enclosed=true' cables.scad` renders whatever the
cables and plugs share with the printed parts, the clamps and the boards, and
`show="plugclash"` renders where a lead crosses another port's plug. An empty
result means they fit. The check needs `enclosed=true` passed on the command
line: setting it inside the file comes too late, because OpenSCAD evaluates a
reassigned variable at its first assignment.

- **USB, 4 leads.** The Pi 5's port tongues are on top (checked on a photo), so
  "LEWY" right-angle USB-A plugs turn toward the back. The rear column (USB 2.0,
  next to GPIO) takes both boards, with 2 x LEWY angled USB-A <-> angled USB-C
  25 cm. Those leads go straight back inside along the right wall. The middle
  column (USB 3.0) takes both probes, with straight USB-A <-> micro-USB. Those
  plugs stick out through the wall cut-out. Each lead makes a short loop at its
  plug and comes back in over the plugs, through the same cut-out (open up to the
  tray above), then runs along the inside of the right wall. All
  four go up the duct at the back right: a slot through every tray and the lid,
  with a snap-in U clip (3.8 mm opening) on each tray. Spare cable goes in loops
  behind the Pi, tied to slot pairs in the back frame. `port_of` in
  `cables.scad` sets which lead uses which port.
- **Port mask (Pi tier, right wall).** One window frames the RJ45 and both USB stacks,
  ~3 mm over the highest plug, with wall above it. Its lintel is a bridge on slim 3 mm
  pillars, clear of the leads running inside. Behind the ports there is a separate
  opening for leads, open to the top, where the probes' leads come back in.
- **Pi power.** Use a 90° USB-C lead angled to the side (USB-C is reversible,
  so it can always point right). The lead runs along the inside of the Pi's front
  edge, out through the front cut-out into a gutter outside the front wall
  (`power_gutter`: the base's floor extended by 9 mm with a 10 mm lip and three hooks that hold the lead, printed
  without supports), and on to the right-front corner. Ethernet and the USB leads
  leave there too, so every lead leaves from one side.
- **JST (SWD + UART).** Probe A's JST end points right and its leads go down a
  slot by the right wall, behind the SD/audio cut-out. Probe B's points left and
  goes down a slot by the left wall, behind the VGA connector. Both pass through
  the lid and the lane trays, then across to the Pico Plus 2's front end. They
  run ~21 cm (A) and ~14 cm (B); extend them if the kit's leads are shorter.
- **Lengths, end to end, including the plugs (estimates):** board A ~15 cm,
  board B ~18 cm, probe A ~36 cm, probe B ~31 cm, JST ~10 / ~7 cm. Buy 25 cm
  for the boards. For the probes, 1 m (easy to get) works, with plugs of any
  length (the micro-USB ends point right, along the long edge): the spare lead winds
  round the spool under each probe (`probe_reel`). The hub is an oval (stadium),
  30 mm across for the lead's bend, under the wider pocket. A 45° flare carries
  the pocket and keeps the turns down. It holds 5 turns, about 76 cm; a 1 m lead
  needs about 3½ (A) and 4 (B). The probe snaps in (`probe_snap`): two springy
  tabs in the long walls, each with a 0.6 mm tooth that holds it gently. To take
  the probe out, bend the tabs outward with a fingernail. The positions of the
  Pi 5's USB ports are estimates (±2 cm).

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
| 16 + 16 | M3 × 10 socket-head screws + M3 nuts, 4 per tier (`tier_join = "screws"`); or 4 M3 threaded rods ≥ 147 mm + 8 nuts (`"rods"`) |
| 12 + module | M2.5 × 6–8 screws driven straight into the standoffs (`fastener = "tap"`, default); or M2.5 nuts + M2.5 × 10 (`"nut"`), or heat-set inserts OD 3.5 + M2.5 × 6 (`"insert"`) |
| 4 | rubber feet, stuck over the base nut traps |
| 1 | 2-channel relay module that switches with a **3.3 V** input (see below) |
| 2 | short USB-A extensions (probe VBUS goes through the relay) |
| 2 | micro-USB power-only pigtails (switched 5 V into the VGA bases' USB POWER sockets) |
| 4 | Dupont jumpers, Pi header to relay inputs (+ 2 more for the optional RUN wires) |

## Power reset: why no hub

By default (`service_tier = false`) the tower has no relay tier: the four USB leads
(two probes, two boards) go straight to the Pi 5 and the lid sits on lane B
(115.5 mm tall). Resetting through the Pi's own ports then cycles all four at
once. The relay scheme below is what `service_tier = true` makes room for.

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
