// YasOS CI rig: an open-frame tower for
//   tier 0  Raspberry Pi 5 (with the Active Cooler)
//   tier 1  lane A: Pimoroni Pico Plus 2 on a Pimoroni Pico VGA Demo Base
//   tier 2  lane B: the same
//   tier 3  service tier: the power-switch module (relays / load switches)
//   lid     two Raspberry Pi Debug Probes in cradles, LEDs on top
//
// Pi 5 and the VGA Demo Base are both 85 x 56 mm, so every tier has one outline.
// Each tray carries the four corner posts up to the next tray; four M3 threaded
// rods run through all posts (nuts in the base and the lid).  Print every part
// flat side down, no supports.  Values marked MEASURE are from drawings/photos:
// check them with calipers on the real boards before printing.
//
//   openscad -D 'part="lane"' -o lane.stl ci_rig.scad

part = "assembly"; // [assembly, base, lane, service, lid]
enclosed = true;    // walls with connector cut-outs on every tier
explode  = 0;       // assembly view only: extra gap between tiers (try 40)
$fn = 48;

/* ---------- boards ---------- */
bw = 85;  bd = 56;                                   // board outline, both boards
pi_holes  = [[3.5,3.5],[61.5,3.5],[3.5,52.5],[61.5,52.5]];   // Pi 5, M2.5
vga_holes = [[3.5,3.5],[81.5,3.5],[3.5,52.5],[81.5,52.5]];   // VGA base, M2.5 (MEASURE)

/* Debug Probe in its case (MEASURE: Elektor gives 37 x 31 x 10) */
probe = [31, 37, 10];        // x, y (long axis toward the back), height
/* power-switch module on the service tier: set its holes to get standoffs,
   leave empty for a slot field (M3 screws / zip ties anywhere) */
switch_holes = [];           // e.g. [[0,0],[44,0],[0,32],[44,32]]
switch_origin = [8, 6];

/* ---------- connector cut-outs (enclosed = true) ----------
   [side, from, to, z0, z1]: side F = front (y = 0 edge of the boards), B = back,
   L = left (x = 0), R = right; from/to along that side in board coordinates;
   z from the top of the tray.  Positions read off photos: MEASURE. */
pi_cuts = [
    ["F",  2, 52, 1, 15],      // USB-C power, 2x micro HDMI, UART JST
    ["R", -1, 57, 2, 24],      // RJ45 + 2x USB stacks
    ["L", 18, 38, 0, 8],       // microSD, under the PCB
    ["B", 55, 88, 6, 24],      // cable exit: probe USB leads round to the USB ports
];
lane_cuts = [
    ["L", 12, 56, 3, 24],      // VGA plug
    ["R",  2, 50, 3, 17],      // microSD + both audio jacks
];
service_cuts = [];
wall_t = 2;

/* ---------- frame ---------- */
gap      = 3;      // free space around the boards (cables, plugs)
back_ch  = 12;     // cable channel behind the boards (USB plugs, JST, GPIO wires)
ring     = 10;     // frame width
corner_r = 5;
plate_t  = 3;      // lane / service tray thickness
base_t   = 4;      // base (holds nut traps)
lid_t    = 4;
post_d   = 10;
rod_d    = 3.4;    // M3 threaded rod
nut_af   = 5.5;    // M3 nut across flats
nut_h    = 2.6;
boss_d   = 6;      // alignment boss on post tops, recess under the next tray
boss_h   = 1.5;
rib_w    = 6;

/* tier heights: top of a tray to the bottom of the next one */
h_pi      = 30;    // 4 standoff + 1.6 PCB + USB/RJ45 stack ~16 + fan intake
h_lane    = 34;    // 5 standoff + 1.6 + headers 8.5 + Pico 1 + vertical JST-SH plugs
h_service = 26;    // relay module ~20 high

/* standoffs */
use_inserts = true;                     // M2.5 heat-set inserts, else self-tap
so_hole = use_inserts ? 3.5 : 2.2;
so_d    = use_inserts ? 7 : 6;
so_h_pi   = 4;
so_h_lane = 5;     // VGA base header pins stick out ~2.5 mm underneath

/* ---------- derived ---------- */
ix0 = -gap;        ix1 = bw + gap;          // inner opening
iy0 = -gap;        iy1 = bd + back_ch;
ox0 = ix0 - ring;  ox1 = ix1 + ring;        // outline
oy0 = iy0 - ring;  oy1 = iy1 + ring;
posts = [[ox0 + ring/2, oy0 + ring/2], [ox1 - ring/2, oy0 + ring/2],
         [ox0 + ring/2, oy1 - ring/2], [ox1 - ring/2, oy1 - ring/2]];

z_lane_a  = base_t + h_pi;
z_lane_b  = z_lane_a + plate_t + h_lane;
z_service = z_lane_b + plate_t + h_lane;
z_lid     = z_service + plate_t + h_service;
total_h   = z_lid + lid_t;
echo(str("outline ", ox1 - ox0, " x ", oy1 - oy0, " mm, height ", total_h,
         " mm -> M3 rod >= ", total_h, " mm (nuts are recessed)"));

/* ---------- helpers ---------- */
function probe_x(cw) = [bw/2 - cw/2 - 3, bw/2 + cw/2 + 3];
module rrect(x0, y0, x1, y1, r, h) {
    linear_extrude(h) offset(r) offset(-r) translate([x0, y0]) square([x1 - x0, y1 - y0]);
}
module outline(h) { rrect(ox0, oy0, ox1, oy1, corner_r, h); }
module ring_plate(t) {
    difference() {
        outline(t);
        translate([ix0, iy0, -1]) cube([ix1 - ix0, iy1 - iy0, t + 2]);
    }
}
// L-shaped ribs from each standoff to the two nearest sides of the frame
module ribs(holes, t) {
    for (h = holes) {
        xa = h[0] < bw/2 ? ix0 - 1 : h[0];
        xb = h[0] < bw/2 ? h[0] : ix1 + 1;
        ya = h[1] < bd/2 ? iy0 - 1 : h[1];
        yb = h[1] < bd/2 ? h[1] : iy1 + 1;
        translate([xa, h[1] - rib_w/2, 0]) cube([xb - xa, rib_w, t]);
        translate([h[0] - rib_w/2, ya, 0]) cube([rib_w, yb - ya, t]);
    }
}
module standoffs(holes, t, h) {
    for (p = holes) translate([p[0], p[1], 0]) difference() {
        cylinder(d = so_d, h = t + h);
        translate([0, 0, t + h - (use_inserts ? 5 : h + t - 0.8)])
            cylinder(d = so_hole, h = 20);
    }
}
module posts_up(t, h) {
    for (p = posts) translate([p[0], p[1], 0]) {
        cylinder(d = post_d, h = t + h);
        translate([0, 0, t + h]) cylinder(d = boss_d, h = boss_h);
    }
}
module rod_holes() { for (p = posts) translate([p[0], p[1], -50]) cylinder(d = rod_d, h = 500); }
module boss_recesses() {
    for (p = posts) translate([p[0], p[1], -0.01]) cylinder(d = boss_d + 0.4, h = boss_h + 0.3);
}
module nut_traps(top_z) {   // hex pockets, top_z = 0: from below, else from above
    for (p = posts) translate([p[0], p[1], top_z == 0 ? -0.01 : top_z - nut_h])
        cylinder(d = nut_af / cos(30) + 0.4, h = nut_h + 0.02, $fn = 6);
}
// outer walls from the tray top to the next tray, vents, connector cut-outs
module walls(t, h, cuts) {
    if (enclosed) difference() {
        translate([0, 0, t - 0.01]) difference() {
            outline(h + 0.01);
            translate([0, 0, -1]) linear_extrude(h + 3)
                offset(r = corner_r - wall_t) offset(-corner_r)
                    translate([ox0, oy0]) square([ox1 - ox0, oy1 - oy0]);
        }
        for (c = cuts) {
            a0 = c[1]; a1 = c[2]; z0 = t + c[3]; z1 = t + c[4];
            if (c[0] == "F") translate([a0, oy0 - 1, z0]) cube([a1 - a0, wall_t + 2, z1 - z0]);
            if (c[0] == "B") translate([a0, oy1 - wall_t - 1, z0]) cube([a1 - a0, wall_t + 2, z1 - z0]);
            if (c[0] == "L") translate([ox0 - 1, a0, z0]) cube([wall_t + 2, a1 - a0, z1 - z0]);
            if (c[0] == "R") translate([ox1 - wall_t - 1, a0, z0]) cube([wall_t + 2, a1 - a0, z1 - z0]);
        }
        vh = h - 12;                                     // vent slots
        if (vh > 4) {
            for (x = [ox0 + ring + 4 : 8 : ox1 - ring - 6], y = [oy0 - 1, oy1 - wall_t - 1])
                translate([x, y, t + 6]) cube([3, wall_t + 2, vh]);
            for (y = [oy0 + ring + 4 : 8 : oy1 - ring - 6], x = [ox0 - 1, ox1 - wall_t - 1])
                translate([x, y, t + 6]) cube([wall_t + 2, 3, vh]);
        }
    }
}
module label(txt, size = 6) {
    linear_extrude(0.8) text(txt, size = size, font = "Liberation Sans:style=Bold",
                             halign = "center", valign = "center");
}

/* ---------- parts ---------- */

// tier 0: floor under the Pi 5, nut traps underneath (stick rubber feet over them)
module base() {
    difference() {
        union() {
            outline(base_t);
            standoffs(pi_holes, base_t, so_h_pi);
            posts_up(base_t, h_pi);
            walls(base_t, h_pi, pi_cuts);
        }
        // vent slots under the Pi (away from the standoffs)
        for (x = [10 : 7 : 52]) translate([x, 10, -1]) rrect(0, 0, 3.5, 36, 1.7, base_t + 2);
        // GPIO wires from the service tier come down the back channel; open it
        translate([ix0 + 6, bd + 2, -1]) rrect(0, 0, ix1 - ix0 - 12, back_ch - 4, 2, base_t + 2);
        rod_holes();
        nut_traps(0);
        translate([bw - 12, -gap - ring/2, base_t - 0.6]) label("YasOS CI", 4.5);
    }
}

// tiers 1 and 2: a VGA Demo Base on M2.5 standoffs, print two
module lane() {
    difference() {
        union() {
            ring_plate(plate_t);
            ribs(vga_holes, plate_t);
            standoffs(vga_holes, plate_t, so_h_lane);
            posts_up(plate_t, h_lane);
            walls(plate_t, h_lane, lane_cuts);
        }
        rod_holes();
        boss_recesses();
    }
}

// tier 3: the power-switch module; back channel open for cables
module service() {
    difference() {
        union() {
            outline(plate_t);
            posts_up(plate_t, h_service);
            walls(plate_t, h_service, service_cuts);
            if (len(switch_holes) > 0)
                for (p = switch_holes) translate([switch_origin[0] + p[0], switch_origin[1] + p[1], 0])
                    difference() { cylinder(d = so_d, h = plate_t + 5);
                                   translate([0, 0, plate_t + 5 - 5]) cylinder(d = so_hole, h = 10); }
        }
        translate([ix0, bd, -1]) rrect(0, 0, ix1 - ix0, back_ch, 2, plate_t + 2);   // cable channel
        if (len(switch_holes) == 0)          // slot field: x anywhere, y every 7 mm
            for (y = [2 : 7 : bd - 6]) translate([4, y, -1]) rrect(0, 0, bw - 8, 3.4, 1.7, plate_t + 2);
        rod_holes();
        boss_recesses();
    }
}

// lid: the two Debug Probes, JST end toward the back channel, LEDs visible
module lid() {
    cw = probe[0] + 0.6 + 3.6;  cl = probe[1] + 0.6 + 3.6;
    xs = probe_x(cw);                                              // centres A, B
    cy0 = bd - cl - 1;
    difference() {
        union() {
            outline(lid_t);
            for (i = [0, 1]) translate([xs[i] - cw/2, cy0, 0]) difference() {
                cube([cw, cl, lid_t + 5]);
                translate([1.8, 1.8, lid_t]) cube([cw - 3.6, cl - 3.6, 10]);
                translate([cw/2 - 10, -1, lid_t + 0.01]) cube([20, cl + 2, 10]);   // cable ends
            }
        }
        translate([ix0, bd, -1]) rrect(0, 0, ix1 - ix0, back_ch, 2, lid_t + 2);       // cables down
        for (x = [6 : 7 : bw - 6]) translate([x, oy0 + 2.5, -1]) rrect(0, 0, 3.5, ring - 1, 1.7, lid_t + 2);
        rod_holes();
        boss_recesses();
        nut_traps(lid_t);
        for (i = [0, 1]) translate([xs[i], cy0 - 7, lid_t - 0.6]) label(i == 0 ? "A" : "B", 6);
    }
}

/* ---------- ghost boards for the assembly view (not printed) ---------- */
module ghost_pi() {
    color("green", 0.6) cube([bw, bd, 1.6]);
    color("silver", 0.7) {
        translate([bw - 21, 2, 1.6])  cube([21 + 2, 16, 13.5]);   // RJ45
        translate([bw - 17, 21, 1.6]) cube([17 + 2, 13, 16]);     // USB stack
        translate([bw - 17, 38, 1.6]) cube([17 + 2, 13, 16]);
        translate([20, 18, 1.6]) cube([30, 30, 12]);              // Active Cooler
    }
    color("black", 0.7) translate([7, bd - 6, 1.6]) cube([51, 5, 8.5]);   // GPIO header
}
module ghost_lane() {
    color([0.15, 0.15, 0.15], 0.7) cube([bw, bd, 1.6]);
    color("darkblue", 0.8) translate([-8, 18, 1.6]) cube([8 + 6, 31, 12.5]);   // VGA
    color("gold", 0.8) {
        translate([bw - 12, 26, 1.6]) cube([14, 7, 6]);   // audio jacks
        translate([bw - 12, 37, 1.6]) cube([14, 7, 6]);
    }
    color("silver", 0.8) translate([bw - 16, 6, 1.6]) cube([15, 15, 2]);      // microSD
    color("black", 0.8) translate([26, 3, 1.6]) cube([21, 51, 8.5]);          // headers + Pico
    color("darkred", 0.8) translate([26, 3, 10.1]) cube([21, 51, 1]);
}
module ghost_probe() { color("white", 0.6) cube(probe); }
module ghost_switch() { color("blue", 0.5) cube([50, 38, 19]); }

module assembly() {
    e = explode;
    color("orange") base();
    translate([0, 0, base_t + so_h_pi]) ghost_pi();
    for (i = [0, 1]) {
        z = (i == 0 ? z_lane_a : z_lane_b) + (i + 1) * e;
        translate([0, 0, z]) color("orange") lane();
        translate([0, 0, z + plate_t + so_h_lane]) ghost_lane();
    }
    translate([0, 0, z_service + 3 * e]) color("orange") service();
    translate([switch_origin[0], switch_origin[1], z_service + 3 * e + plate_t]) ghost_switch();
    translate([0, 0, z_lid + 4 * e]) color("orange") lid();
    cw = probe[0] + 0.6 + 3.6;  cl = probe[1] + 0.6 + 3.6;
    for (x = probe_x(cw))
        translate([x - probe[0]/2, bd - cl - 1 + 2.1, z_lid + 4 * e + lid_t]) ghost_probe();
}

if (part == "assembly") assembly();
else if (part == "base") base();
else if (part == "lane") lane();
else if (part == "service") service();
else if (part == "lid") lid();
