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

part = "assembly"; // [assembly, base, lane, service, lid, pi_top, pi_clamp]
                    // pi_top: flat cover for the Pi tier alone (base + pi_top = a Pi 5 case)
enclosed = true;    // walls with connector cut-outs on every tier
explode  = 0;
case_alpha = 1;     // assembly view only: < 1 makes the printed parts see-through
base_floor = "ring"; // [ring, solid]: ring = frame + ribs like the lane trays (faster
                    // print, air from below), solid = full floor with vent slots       // assembly view only: extra gap between tiers (try 40)
$fn = 48;

/* ---------- boards ---------- */
bw = 85;  bd = 56;                                   // board outline, both boards
pi_holes  = [[3.5,3.5],[61.5,3.5],[3.5,52.5],[61.5,52.5]];   // Pi 5, M2.5
vga_holes = [[3.5,3.5],[81.5,3.5],[3.5,52.5],[81.5,52.5]];   // VGA base, M2.5 (MEASURE)

/* Debug Probe in its case (MEASURE: Elektor gives 37 x 31 x 10) */
probe = [31, 37, 10];        // x, y (long axis toward the back), height
// probe_rot: the probes lie along the long edge (JST to the left, micro-USB to the right),
// A in front, B behind; the case gets 20 mm deeper for it (back channel 12 -> 32)
probe_rot = true;
// probe_diag: A in front on the right (turned round: JST right, micro-USB left), B behind
// on the left; the spools only meet at their corners, so the case grows ~5 mm, not 20
probe_diag = true;
/* power-switch module on the service tier: set its holes to get standoffs,
   leave empty for a slot field (M3 screws / zip ties anywhere) */
switch_holes = [];           // e.g. [[0,0],[44,0],[0,32],[44,32]]
switch_origin = [8, 6];

/* ---------- what the Pi rests on (used by the cut-outs below) ---------- */
pi_support  = "grid";    // [grid, standoffs]
so_h_pi   = pi_support == "grid" ? 1.5 : 4;   // Pi PCB underside above the base floor

/* ---------- connector cut-outs (enclosed = true) ----------
   [side, from, to, z0, z1]: side F = front (y = 0 edge of the boards), B = back,
   L = left (x = 0), R = right; from/to along that side in board coordinates;
   z from the top of the tray.  Positions read off photos: MEASURE. */
pi_cuts = [
    ["F", -1, 52, max(0, so_h_pi - 3), so_h_pi + 13],      // USB-C power, 2x micro HDMI, UART JST (starts at -1:
                               //  its left pillar must clear the front-left clamp boss)
    // port mask: one window round the RJ45 and both USB stacks, ~3 mm over the highest plug,
    // its lintel on slim pillars (3 mm deep) clear of the leads running inside the wall
    ["R", -1, 53, max(0, so_h_pi - 2), so_h_pi + 21.5, 3],
    // the way in for leads, behind the ports; open to the top (the tier above closes it)
    ["R", 59, 67, max(0, so_h_pi - 2), 99],
    ["L", 18, 38, 0, so_h_pi + 4],       // microSD, under the PCB
];
lane_cuts = [
    ["L", 12, 56, 3, 24],      // VGA plug
    ["R",  2, 50, 3, 17],      // microSD + both audio jacks
];
service_cuts = [];
wall_t = 2;
vent_pitch = 20;   // vent spacing in the walls; 0 = no vents
vent_w     = 12;   // vent width: few wide windows print much faster than many 3 mm slots

/* ---------- frame ---------- */
gap      = 3;      // free space around the boards (cables, plugs)
gap_r    = 3;      // right side: the USB plugs stick out through the wall and the leads
                   // fold back outside (9 would keep 90-degree plugs inside instead)
lane_dx  = gap_r - gap;   // the lane boards move with the right wall (SD slot as reachable)
back_ch  = probe_rot ? (probe_diag ? 20 : 32) : 12;   // diagonal: 5 mm round the spools to wind the leads   // channel behind the boards (USB plugs, GPIO wires)
ring     = 10;     // frame width
corner_r = 5;
plate_t  = 3;      // lane / service tray thickness
base_t   = 4;      // base (holds nut traps)
lid_t    = 3;
post_d   = 10;
rod_d    = 3.4;    // M3 clearance (screws, or threaded rod)
/* how the tiers hold together:
   "screws": an M3 nut slides sideways into each post, its top join_nut_depth below
   the post top; the tray above is fixed with M3 x 10 screws from inside its own
   posts, which are hollow (a 2.5 mm hex key reaches the head through the hole in the
   post top; slide the next nut in after tightening).
   "rods":   four M3 threaded rods through every post, nuts in the base and the lid. */
tier_join      = "screws";  // [screws, rods]
join_nut_depth = 3;
join_nut_tol   = [0.4, 0.5];  // side-slot clearance: across flats, height
post_bore      = 6.4;       // M3 socket head 5.5 + clearance
nut_af   = 5.5;    // M3 nut across flats
nut_h    = 2.6;
boss_d   = 6;      // alignment boss on post tops, recess under the next tray
boss_h   = 1.5;
rib_w    = 6;

/* tier heights: top of a tray to the bottom of the next one */
h_pi      = so_h_pi + 32;   // Pi PCB + heatsink + NVMe HAT with SSD + room (MEASURE the stack)
h_lane    = 34;    // 5 standoff + 1.6 + headers 8.5 + Pico 1 + vertical JST-SH plugs
/* spools (reel tier) */
spool_d    = 42;
spool_wall = 2.4;
spool_h    = 24;   // 4 turns of a 3.5 mm lead in one layer: ~57 cm per spool
spool_lip  = 4;
spool_c    = [[18, 26], [70, 26]];   // centres: coils up to ~50 mm across
// extra tier under the lid: "reels" = two spools for the probes' spare USB lead (1 m
// leads leave ~60 cm each), "relays" = the power-switch module, "none" = lid on lane B
extra_tier = "none";    // [none, reels, relays]: default none, the spools sit under the probes
h_service = extra_tier == "reels" ? spool_h + 3 : 26;   // spools / relay module ~20

/* standoffs */
fastener = "tap";   // [tap, nut, insert]: M2.5 nut pressed into a hex pocket under each
                    // standoff (screw from the top), heat-set insert (OD 3.5), self-tapping
board_screw = 2.5;  // [2.5, 3] board screws: the Pi 5's holes are 2.7 mm, so M2.5 only;
                    // M3 only for a board whose holes are >= 3.2 mm
m3b = board_screw == 3;
m25_nut_af = m3b ? 5.5 : 5.0;   // board nut across flats
m25_nut_h  = m3b ? 2.4 : 2.0;
so_hole = fastener == "insert" ? (m3b ? 4.0 : 3.5) : fastener == "nut" ? (m3b ? 3.4 : 2.8)
                               : (m3b ? 2.6 : 2.2);
so_d    = fastener == "insert" ? (m3b ? 8 : 7) : fastener == "nut" ? (m3b ? 9 : 8.5) : 6;
// The Pi carries a screwed-on heatsink and an NVMe HAT on standoffs, so nothing can
// be screwed in from the top.  "under": swap the Pi's four bottom screws, one at a
// time, for longer M2.5 screws driven up from under the base, through the standoff
// and the Pi into the HAT's standoffs; the heads sit in counterbores underneath.
// "pocket" (default): no screws in the Pi at all.  Whatever already sits under its
// holes (the screw heads or nuts of the HAT standoffs) drops into a pocket in each
// standoff top, which keeps the Pi from sliding; two clamps (part "pi_clamp", shaped
// _|-|_) press the HAT down over its standoff screws and are screwed to the base.
pi_fastener = "pocket";  // [pocket, under, tap, nut, insert]
pi_so_d = (pi_fastener == "under" || pi_fastener == "pocket") ? 9.5 : so_d;
pi_pocket_d = 6.6;       // fits an M2.5 pan head or a 5 mm hex nut (MEASURE)
pi_pocket_h = 2.4;
/* what the Pi rests on: "grid" = a low lattice instead of standoffs; the cells are
   centred on the Pi's holes, so the screw heads / nuts under them drop into cells.
   "standoffs" = four standoffs (pi_fastener decides their holes). */
pi_grid_p   = [34.8, 36.75];   // 3 x (58 / 5, 49 / 4): no rib passes under a hole
pi_grid_rib = 2.5;
// lowered areas: parts on the underside of the Pi (microSD socket; MEASURE yours)
pi_grid_relief = [[-1, 17, 18, 39, 2.0]];   // [x0, y0, x1, y1, depth]
/* Pi clamps: they run front to back along the hole lines, where nothing sits on
   the board edge (GPIO starts at x 7, USB/Ethernet at x ~65) */
pi_clamps    = true;
pi_stack_h   = 22;       // MEASURE: from the Pi PCB's underside to the top of the HAT's screw heads
pi_stack_top = so_h_pi + pi_stack_h;   // above the base floor
clamp_x      = [1.5, 61.5];   // centre lines; the left one keeps clear of the USB-C power plug
clamp_w      = 6;
clamp_t      = 4;        // bridge thickness
clamp_relief = 2.5;      // bridge clearance over the HAT between the pads
clamp_yf     = -7;       // screw bosses, front ring
clamp_yb     = bd + back_ch + 5;   //   back ring
clamp_boss_d = 6.5;
clamp_boss_h = 5;
pi_head_d = 5.2;         // M2.5 pan / socket head + clearance
pi_head_h = 2.2;
so_h_lane = 5;     // VGA base header pins stick out ~2.5 mm underneath

/* ---------- derived ---------- */
ix0 = -gap;        ix1 = bw + gap_r;        // inner opening
iy0 = -gap;        iy1 = bd + back_ch;
ox0 = ix0 - ring;  ox1 = ix1 + ring;        // outline
oy0 = iy0 - ring;  oy1 = iy1 + ring;
posts = [[ox0 + ring/2, oy0 + ring/2], [ox1 - ring/2, oy0 + ring/2],
         [ox0 + ring/2, oy1 - ring/2], [ox1 - ring/2, oy1 - ring/2]];

pi_screw_len = base_t - pi_head_h + so_h_pi + 1.6 + 4;   // 4 mm into the HAT standoff
if (pi_fastener == "under")
    echo(str("Pi from below: M2.5 x ", ceil(pi_screw_len / 2) * 2, " (about ", pi_screw_len, " mm)"));
z_lane_a  = base_t + h_pi;
z_lane_b  = z_lane_a + plate_t + h_lane;
z_service = z_lane_b + plate_t + h_lane;
// the relay tier is optional: the USB leads go straight to the Pi, so by default the
// lid sits on lane B and is screwed into its nut blocks
service_tier = extra_tier != "none";
z_lid     = service_tier ? z_service + plate_t + h_service : z_service;
// probe_reel: each Debug Probe sits on its own spool on the lid; the probe's spare USB
// lead winds round the spool under it (hub = rounded rectangle round the pocket,
// corners r 15 for the lead's bend, 45-degree flare at the top holds the turns)
probe_reel = true;
// oval (stadium) hub, 2 x reel_r across (the lead's bend), under a wider pocket; the
// flare widens it to carry the pocket and keep the turns down
reel_r     = 15;
reel_turns_max = 5;
reel_coil_h = reel_turns_max * 3.7 + 1;
reel_flare = 5.5;               // 45 degrees, hub 30 -> cap 41 across
reel_lip   = reel_flare;
reel_h     = reel_coil_h + reel_flare + 1.2;
// probe_snap: the probe snaps into its pocket (two springy tabs with small teeth that
// hold it gently) instead of a screwed-on cover
probe_snap = true;
snap_tooth = 0.6;
// enclosed top: the lid carries walls up past the probe covers and a flat roof on top
top_closed = true;
h_top     = ceil((probe_reel ? reel_h : 0) + probe[2] + 0.4 + (probe_snap ? snap_tooth + 1 : 2) + 3);
roof_t    = 3;
total_h   = z_lid + lid_t + (top_closed ? h_top + roof_t : 0);
// the probes' JST leads go down here, in front of the spools (lid, extra tier, lane trays)
jst_slot_y = [-10.3, -6.8];
echo(str("outline ", ox1 - ox0, " x ", oy1 - oy0, " mm, height ", total_h, " mm",
         tier_join == "rods" ? str(" -> M3 rod >= ", total_h, " mm") : ""));

vga_l = [for (h = vga_holes) [h[0] + lane_dx, h[1]]];

/* ---------- cable guides ----------
   The four USB leads run up a duct at the back right: a slot through the frame of
   every tray and the lid, one above the other, with a snap-in U wall around it on
   each tray (3.8 mm opening, push the lead through).  In the Pi tier they run from
   the duct along the right wall to the ports: zip-tie slot pairs in the floor frame. */
duct      = [60, 86, bd + back_ch, bd + back_ch + 7];   // x0, x1, y0, y1: in the back frame, open toward the inside
duct_wall = 1.6;
duct_h    = 7;
duct_open = 3.8;
tie_y     = [];                     // zip-tie slot pairs along the right frame, Pi tier
// spare cable: loops standing parallel to the back wall in the Pi tier, behind the
// Pi and its HAT (20 mm deep, the full tier high), tied to slot pairs in the back frame
tie_back_x = [20, 44];   // under the two columns of loops
// rotated probes: two slots along the left wall, clear of the VGA connectors and the
// pillars of the VGA cut-out lintels: [x0, x1, y0, y1]
jst_slots_l = probe_diag ? [[88, 94.5, 55.5, 65.5], [-10.5, -4, 61, 71]]   // 6.5 x 10: a JST-SH plug passes   // A: right, behind the SD/audio cut-out
                         : [[-10, -7, -2, 6], [-10, -7, 62, 76]];
module jst_slot(t) {
    if (probe_rot) for (r = jst_slots_l) translate([r[0], r[2], -1]) rrect(0, 0, r[1] - r[0], r[3] - r[2], 1.4, t + 2);
    else translate([8, jst_slot_y[0], -1]) rrect(0, 0, bw - 16, jst_slot_y[1] - jst_slot_y[0], 1.5, t + 2);
}
module duct_hole(t) { translate([duct[0], duct[2] - 1, -1]) cube([duct[1] - duct[0], duct[3] - duct[2] + 1, t + 2]); }
// U guide round the duct, open toward the inside: lay the leads in from the front
module duct_clip(t) {
    for (x = [duct[0] - duct_wall, duct[1]])
        translate([x, duct[2], t - 0.01]) cube([duct_wall, duct[3] - duct[2] + duct_wall, duct_h]);
    translate([duct[0] - duct_wall, duct[3], t - 0.01]) cube([duct[1] - duct[0] + 2 * duct_wall, duct_wall, duct_h]);
}
module tie_slots(t) {
    for (y = tie_y, x = [ix1 + 1.2, ox1 - wall_t - 2.4])
        translate([x, y - 2, -1]) cube([1.6, 4, t + 2]);
    for (x = tie_back_x, y = [iy1 + 1.2, oy1 - wall_t - 2.4])
        translate([x - 2, y, -1]) cube([4, 1.6, t + 2]);
}

/* ---------- helpers ---------- */
probe_gap = probe_reel ? 22 : 12;   // between the probe pockets: 10 mm between the spool flares for the leads
function probe_x(cw) = [bw/2 - cw/2 - probe_gap / 2, bw/2 + cw/2 + probe_gap / 2];
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
module standoffs(holes, t, h, d = so_d) {
    for (p = holes) translate([p[0], p[1], 0]) cylinder(d = d, h = t + h);
}
// cut at tray level, after the plate is joined, so the holes go through it
module standoff_holes(holes, t, h, mode = fastener) {
    for (p = holes) translate([p[0], p[1], 0]) {
        if (mode == "under") {
            translate([0, 0, -1]) cylinder(d = 2.9, h = t + h + 2);
            translate([0, 0, -0.01]) cylinder(d = pi_head_d + 0.4, h = pi_head_h + 0.01);
        }
        else if (mode == "pocket") {
            translate([0, 0, -1]) cylinder(d = 2.9, h = t + h + 2);
            translate([0, 0, t + h - pi_pocket_h]) cylinder(d = pi_pocket_d, h = 10);
        }
        else if (mode == "insert") translate([0, 0, t + h - 5]) cylinder(d = so_hole, h = 10);
        else if (mode == "tap") translate([0, 0, 0.8]) cylinder(d = so_hole, h = t + h);
        else {
            translate([0, 0, -1]) cylinder(d = so_hole, h = t + h + 2);
            translate([0, 0, -0.01])
                cylinder(d = (m25_nut_af + 0.3) / cos(30), h = m25_nut_h + 0.4, $fn = 6);
        }
    }
}
// With walls and screw joins the walls carry the stack, so a post is only a nut
// block at the top (on a 45-degree gusset into the corner of the walls, printable
// without support) and, with seat = true, a low ring under this tray's screw head.
post_cap_h  = join_nut_depth + nut_h + 0.3 + 2.2;   // block: nut slot + 1 mm floor + margin
post_seat_h = 2;
cut_posts   = enclosed && tier_join == "screws";
module posts_up(t, h, seat = true) {
    for (p = posts) translate([p[0], p[1], 0]) {
        if (cut_posts) {
            sx = p[0] < bw / 2 ? -1 : 1;  sy = p[1] < bd / 2 ? -1 : 1;
            zb = t + h - post_cap_h;
            c = ring / 2 - wall_t;                  // centre -> inner corner of the walls
            gh = c * sqrt(2) + post_d / 2;          // 45 degrees down to that corner
            // clipped to the outline: the corners are rounded, and the gusset's corner would
            // otherwise poke ~0.7 mm out of the outer wall
            intersection() {
                hull() {
                    translate([0, 0, zb]) cylinder(d = post_d, h = post_cap_h);
                    translate([sx * c - 1, sy * c - 1, zb - gh]) cube([2, 2, 1]);
                }
                translate([-p[0], -p[1], -1]) outline(t + h + 2);
            }
            if (seat) cylinder(d = post_d, h = t + post_seat_h);
        } else cylinder(d = post_d, h = t + h);
        translate([0, 0, t + h]) cylinder(d = boss_d, h = boss_h);
    }
}
module rod_holes() { for (p = posts) translate([p[0], p[1], -50]) cylinder(d = rod_d, h = 500); }
// "screws": side nut slot near the post top, opening toward the middle of the case,
// and (bore = true) the hollow post the screw holding this tray goes down
module post_joins(t, h, bore = true) {
    if (tier_join == "screws") for (p = posts) translate([p[0], p[1], 0]) {
        zn = t + h - join_nut_depth - nut_h - join_nut_tol[1];
        ang = atan2(bd / 2 - p[1], bw / 2 - p[0]);
        translate([0, 0, zn]) rotate([0, 0, ang]) {
            cylinder(d = (nut_af + join_nut_tol[0]) / cos(30), h = nut_h + join_nut_tol[1], $fn = 6);
            translate([0, -(nut_af + join_nut_tol[0]) / 2, 0])
                cube([post_d, nut_af + join_nut_tol[0], nut_h + join_nut_tol[1]]);
        }
        if (bore && !cut_posts) translate([0, 0, t]) cylinder(d = post_bore, h = zn - 1.0 - t);
    }
}
join_screw = plate_t + join_nut_depth + nut_h + 1.2;
if (tier_join == "screws")
    echo(str("tiers: M3 x ", ceil(join_screw / 2) * 2, " socket-head screws + M3 nuts, 4 per tier"));
module boss_recesses() {
    for (p = posts) translate([p[0], p[1], -0.01]) cylinder(d = boss_d + 0.4, h = boss_h + 0.3);
}
module nut_traps(top_z) {   // hex pockets, top_z = 0: from below, else from above
    for (p = posts) translate([p[0], p[1], top_z == 0 ? -0.01 : top_z - nut_h])
        cylinder(d = nut_af / cos(30) + 0.4, h = nut_h + 0.02, $fn = 6);
}
// outer walls from the tray top to the next tray, vents, connector cut-outs
// a vertical slot with a 45-degree pointed top (needs no bridge), or a plain rectangle
// of the same height (flat: a short bridge across the slot, fewer perimeter turns)
module vent_x(w, d, hv, flat = false) {   // spans x, through y
    translate([0, d, 0]) rotate([90, 0, 0]) linear_extrude(d)
        polygon(flat ? [[0, 0], [w, 0], [w, hv + w / 2], [0, hv + w / 2]]
                     : [[0, 0], [w, 0], [w, hv], [w / 2, hv + w / 2], [0, hv]]);
}
module vent_y(w, d, hv, flat = false) {   // spans y, through x
    translate([d, 0, 0]) rotate([0, 0, 90]) vent_x(w, d, hv, flat);
}
function near_cut(side, pos, cuts, vw = vent_w) =
    len([for (c = cuts) if (c[0] == side && pos > c[1] - lintel_pw - vw - 1 && pos < c[2] + lintel_pw + 1) 1]) > 0;
lintel_d  = 5;     // lintel depth inside the wall: the bridge is wall_t + lintel_d wide
lintel_t  = 1.8;
lintel_pw = 5;     // width of the pillars carrying each end of the lintel
// break-away prop under the middle of a long lintel: a thin rib with one layer of air
// under the bridge, snapped off after printing (it would stand in the plug opening)
lintel_props    = true;
lintel_prop_min = 30;    // spans longer than this get a prop
lintel_prop_w   = 1.2;   // rib thickness along the wall
lintel_prop_gap = 0.2;   // air under the bridge = one layer
// a bridge over each cut-out: a lintel inside the wall on two pillars standing on the frame
module lintels(t, h, cuts) {
    for (c = cuts) if (c[4] < h - 0.5) {
        // pillars reach 0.3 mm into the opening and the lintel 0.05 mm below its top,
        // so no face of the bridge lies exactly on a face of the cut (non-manifold)
        a0 = c[1] - lintel_pw + 0.3; a1 = c[2] + lintel_pw - 0.3; z1 = t + c[4] - 0.05;
        ld = len(c) > 5 ? c[5] : lintel_d;   // per cut-out lintel depth
        lt = min(lintel_t, t + h - z1);
        span = a1 - a0;
        if (c[0] == "F" || c[0] == "B") {
            y = c[0] == "F" ? oy0 + wall_t - 0.01 : oy1 - wall_t - ld + 0.01;
            translate([a0, y, z1]) cube([span, ld, lt]);
            for (x = [a0, a1 - lintel_pw]) translate([x, y, t - 0.01]) cube([lintel_pw, ld, z1 - t + lt]);
            if (lintel_props && c[2] - c[1] > lintel_prop_min)
                translate([(c[1] + c[2] - lintel_prop_w) / 2, c[0] == "F" ? oy0 + 0.3 : y, t - 0.01])
                    cube([lintel_prop_w, ld + wall_t - 0.3, z1 - lintel_prop_gap - t + 0.01]);
        } else {
            x = c[0] == "L" ? ox0 + wall_t - 0.01 : ox1 - wall_t - ld + 0.01;
            translate([x, a0, z1]) cube([ld, span, lt]);
            for (y = [a0, a1 - lintel_pw]) translate([x, y, t - 0.01]) cube([ld, lintel_pw, z1 - t + lt]);
            if (lintel_props && c[2] - c[1] > lintel_prop_min)
                translate([c[0] == "L" ? ox0 + 0.3 : x, (c[1] + c[2] - lintel_prop_w) / 2, t - 0.01])
                    cube([ld + wall_t - 0.3, lintel_prop_w, z1 - lintel_prop_gap - t + 0.01]);
        }
    }
}
module walls(t, h, cuts, vw = vent_w, flat = false) {
    if (enclosed) union() { lintels(t, h, cuts); difference() {
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
        vh = h - 14 - (vw - 3) / 2;                      // vent slots
        if (vh > 4 && vent_pitch > 0) {
            for (x = [ox0 + ring + 4 : vent_pitch : ox1 - ring - 3 - vw], sd = ["F", "B"])
                if (!near_cut(sd, x, cuts, vw))
                    translate([x, sd == "F" ? oy0 - 1 : oy1 - wall_t - 1, t + 6]) vent_x(vw, wall_t + 2, vh, flat);
            for (y = [oy0 + ring + 4 : vent_pitch : oy1 - ring - 3 - vw], sd = ["L", "R"])
                if (!near_cut(sd, y, cuts, vw))
                    translate([sd == "L" ? ox0 - 1 : ox1 - wall_t - 1, y, t + 6]) vent_y(vw, wall_t + 2, vh, flat);
        }
    } }
}
module label(txt, size = 6) {
    linear_extrude(0.8) text(txt, size = size, font = "Liberation Sans:style=Bold",
                             halign = "center", valign = "center");
}

/* ---------- parts ---------- */

// tier 0: floor under the Pi 5, nut traps underneath (stick rubber feet over them)
// power lead gutter: the Pi's power lead (90-degree USB-C, cable to the right) leaves
// through the front cut-out into this gutter outside the front wall and runs to the
// right-front corner, where the Ethernet and USB leads leave too.  It extends the base's
// floor, so it prints without supports.
power_gutter = true;
gutter_w   = 9;
gutter_lip = 10;     // lip above the floor (the hooks sit just over a ~5 mm lead)
gutter_hooks  = [55, 75, 92];   // along the stretch where the lead lies in the gutter
gutter_hook_w = 8;
module gutter() {
    x0 = 0;
    translate([0, 0, 0]) rrect(x0, oy0 - gutter_w, ox1, oy0 + corner_r, 2, base_t);
    translate([x0, oy0 - gutter_w, 0]) cube([ox1 - x0 - corner_r, 1.6, base_t + gutter_lip]);
    translate([x0, oy0 - gutter_w, 0]) cube([1.6, gutter_w, base_t + gutter_lip]);
    // hooks on the lip: 4 mm toward the wall, 45 degrees underneath (no supports); the lead
    // (~5 mm) presses past the 3.4 mm gap to the wall and stays in
    for (x = gutter_hooks) let(y0 = oy0 - gutter_w + 1.6, zt = base_t + gutter_lip)
        translate([x - gutter_hook_w / 2, 0, 0]) rotate([90, 0, 90]) linear_extrude(gutter_hook_w)
            polygon([[y0 - 0.01, zt - 5.5], [y0 + 4, zt - 1.5], [y0 + 4, zt], [y0 - 0.01, zt]]);
}
module base() {
    difference() {
        union() {
            if (base_floor == "solid") outline(base_t);
            else { ring_plate(base_t); if (pi_support != "grid") ribs(pi_holes, base_t); }
            if (pi_support == "grid") pi_grid();
            else standoffs(pi_holes, base_t, so_h_pi, pi_so_d);
            posts_up(base_t, h_pi, seat = false);
            walls(base_t, h_pi, pi_cuts);
            if (power_gutter) gutter();
            if (pi_clamps) for (x = clamp_x, y = [clamp_yf, clamp_yb])
                translate([x, y, 0]) cylinder(d = clamp_boss_d, h = base_t + clamp_boss_h);
        }
        if (pi_support != "grid") standoff_holes(pi_holes, base_t, so_h_pi, pi_fastener);
        else for (r = pi_grid_relief)
            translate([r[0], r[1], base_t + so_h_pi - r[4]]) cube([r[2] - r[0], r[3] - r[1], 10]);
        if (pi_clamps) for (x = clamp_x, y = [clamp_yf, clamp_yb])   // M3 self-tapping
            translate([x, y, 1]) cylinder(d = 2.5, h = 50);
        // a solid floor under a grid stays flat: no vent slots, no channel opening
        if (pi_support != "grid") {
            for (x = [10 : 7 : 52]) translate([x, 10, -1]) rrect(0, 0, 3.5, 36, 1.7, base_t + 2);
            translate([ix0 + 6, bd + 2, -1]) rrect(0, 0, ix1 - ix0 - 12, back_ch - 4, 2, base_t + 2);
        }
        if (tier_join == "rods") rod_holes();     // screws: holes only in the nut blocks,
        else for (p = posts) translate([p[0], p[1], base_t + 0.5]) cylinder(d = rod_d, h = 500);
        post_joins(base_t, h_pi);   // hollow too: only the nut near the top carries load
        tie_slots(base_t);
        if (tier_join == "rods") nut_traps(0);
        translate([bw - 12, -gap - ring/2, base_t - 0.6]) label("YasOS CI", 4.5);
    }
}

// floor crossbars in the lane trays (plate thickness; the VGA base's header pins clear
// them by ~2.5 mm); cables cross these tiers above them
lane_bars   = true;
lane_bar_x  = [28, 57];
lane_bar_y  = [19, 38];   // none across the channel behind the board: plugs pass there (20 mm deep)
lane_bar_w  = 2.5;
module lane_crossbars(t) {
    for (x = lane_bar_x) translate([x + lane_dx - lane_bar_w / 2, iy0 - 1, 0]) cube([lane_bar_w, iy1 - iy0 + 2, t]);
    for (y = lane_bar_y) translate([ix0 - 1, y - lane_bar_w / 2, 0]) cube([ix1 - ix0 + 2, lane_bar_w, t]);
}

// tiers 1 and 2: a VGA Demo Base on M2.5 standoffs, print two
module lane() {
    difference() {
        union() {
            ring_plate(plate_t);
            ribs(vga_l, plate_t);
            if (lane_bars) lane_crossbars(plate_t);
            standoffs(vga_l, plate_t, so_h_lane);
            posts_up(plate_t, h_lane);
            walls(plate_t, h_lane, lane_cuts);
            duct_clip(plate_t);
        }
        duct_hole(plate_t);
        jst_slot(plate_t);
        standoff_holes(vga_l, plate_t, so_h_lane);
        rod_holes();
        boss_recesses();
        post_joins(plate_t, h_lane);
    }
}

// tier 3: the power-switch module; back channel open for cables
switch_abs = [for (p = switch_holes) [switch_origin[0] + p[0], switch_origin[1] + p[1]]];
// spools for the spare probe leads: a hollow hub (3.5 mm lead: bend no tighter than
// ~42 mm) with a 45-degree flare at the top that keeps the turns down (no supports)
function spool_turn() = PI * (spool_d + 3.5);
if (probe_reel) echo(str("probe spools: ", reel_turns_max, " turns of ~", round(reel_turn()), " mm = ~",
    round(reel_turns_max * reel_turn()), " mm of lead each"));
if (extra_tier == "reels") echo(str("reels: ", floor((spool_h - spool_lip - 2) / 3.7), " turns of ", round(spool_turn()),
         " mm = ", round(floor((spool_h - spool_lip - 2) / 3.7) * spool_turn()), " mm of lead per spool in one layer"));
module spools(t) {
    for (c = spool_c) translate([c[0], c[1], t - 0.01]) difference() {
        union() {
            cylinder(d = spool_d, h = spool_h);
            translate([0, 0, spool_h - spool_lip - 1.2]) cylinder(d1 = spool_d, d2 = spool_d + 2 * spool_lip, h = spool_lip);
            translate([0, 0, spool_h - 1.2]) cylinder(d = spool_d + 2 * spool_lip, h = 1.2);
        }
        translate([0, 0, -1]) cylinder(d = spool_d - 2 * spool_wall, h = spool_h + 2);
        // slit to tuck the start of the lead in
        translate([spool_d / 2 - spool_wall - 1, -1, spool_h - 6]) cube([spool_wall + 6, 2, 10]);
    }
}
module service() {
    difference() {
        union() {
            outline(plate_t);
            posts_up(plate_t, h_service);
            walls(plate_t, h_service, service_cuts);
            duct_clip(plate_t);
            if (extra_tier == "reels") spools(plate_t);
            else standoffs(switch_abs, plate_t, 5);
        }
        if (extra_tier != "reels") standoff_holes(switch_abs, plate_t, 5);
        if (extra_tier == "reels") for (c = spool_c) translate([c[0], c[1], -1]) cylinder(d = spool_d - 2 * spool_wall, h = 50);
        translate([ix0, bd, -1]) rrect(0, 0, ix1 - ix0, back_ch, 2, plate_t + 2);   // cable channel
        // front slot: the probes' JST leads go down in front of the boards (the Pico Plus 2
        // has SWD and UART at its front end); the lane trays leave the same 3 mm gap
        jst_slot(plate_t);
        if (extra_tier != "reels" && len(switch_holes) == 0)   // slot field: x anywhere, y every 7 mm
            for (y = [2 : 7 : bd - 6]) translate([4, y, -1]) rrect(0, 0, bw - 8, 3.4, 1.7, plate_t + 2);
        rod_holes();
        boss_recesses();
        post_joins(plate_t, h_service);
        duct_hole(plate_t);
    }
}

// lid: the two Debug Probes, JST end toward the back channel, LEDs visible
module lid() {
    cw = probe[0] + 0.6 + 3.6;  cl = probe[1] + 0.6 + 3.6;
    xs = probe_x(cw);                                              // centres A, B
    cy0 = probe_cy0();
    zc = probe_floor_z();                                          // pocket floor, from the lid's underside
    difference() {
        union() {
            // open floor (frame, crossbars, a pad under each spool) so leads pass with their plugs
            if (lid_open_floor) {
                ring_plate(lid_t);
                lane_crossbars(lid_t);
                if (probe_reel) for (i = [0, 1]) at_probe(i) translate([0, 0, -0.01]) linear_extrude(lid_t + 0.02) reel_2d(cw, cl, 2);
            } else outline(lid_t);
            if (top_closed) { posts_up(lid_t, h_top); walls(lid_t, h_top, [], lid_vent_w, lid_vent_flat); }
            if (probe_reel) for (i = [0, 1]) at_probe(i) reel(cw, cl);
            // on a spool the pocket starts on the flare top: its corners stay inside the flare
            for (i = [0, 1]) let(z0 = probe_reel ? zc - 0.01 : 0, fl = probe_reel ? 0.01 : lid_t)
                at_probe(i) translate([-cw/2, -cl/2, z0]) {
                    difference() {
                        cube([cw, cl, fl + probe_pocket_h]);
                        translate([1.8, 1.8, fl]) cube([cw - 3.6, cl - 3.6, 20]);
                        translate([cw/2 - 10, -1, fl + 0.01]) cube([20, cl + 2, 20]);   // cable ends
                        // snap tabs: slits beside a 12 mm strip of each long wall, almost to the floor
                        if (probe_snap) for (x = [-1, cw - 1.8 - 1], y = [cl / 2 - 7, cl / 2 + 6])
                            translate([x, y, fl + 1.2]) cube([1.8 + 2, 1, 20]);
                    }
                    // teeth: flat underneath over the probe's top edge, a lead-in slope on top
                    if (probe_snap) for (sd = [0, 1]) let(zt = fl + probe[2] + 0.2)
                        translate([sd == 0 ? 1.8 : cw - 1.8, cl / 2 - 6, zt]) mirror([sd, 0, 0])
                            rotate([90, 0, 0]) mirror([0, 0, 1]) linear_extrude(12)
                                polygon([[0, 0], [snap_tooth, 0], [0, snap_tooth + 0.6]]);
                }
            for (p = probe_screws()) translate([p[0], p[1], zc - (probe_reel ? 0.01 : lid_t)])
                cylinder(d = probe_reel ? 6 : 6.5, h = (probe_reel ? 0 : lid_t) + probe_pocket_h);
        }
        if (!probe_rot) translate([ix0, bd, -1]) rrect(0, 0, ix1 - ix0, back_ch, 2, lid_t + 2);   // USB leads down
        jst_slot(lid_t);                                                               // JST leads down
        for (x = [6 : 7 : bw - 6]) translate([x, oy0 + 2.5, -1]) rrect(0, 0, 3.5, ring - 1, 1.7, lid_t + 2);
        rod_holes();
        boss_recesses();
        duct_hole(lid_t);
        if (tier_join == "rods") nut_traps(lid_t);
        else if (top_closed) post_joins(lid_t, h_top);
        else for (p = posts) translate([p[0], p[1], lid_t - 2]) cylinder(d = 6.4, h = 10);   // screw heads
        for (p = probe_screws()) translate([p[0], p[1], zc + probe_pocket_h - 8]) cylinder(d = 2.5, h = 50);   // M3 self-tap
    }
}
function reel_hub_l() = probe_cl() + 10;   // long enough that the cap carries the pocket's corners
module reel_2d(cw, cl, grow = 0) {   // stadium, long axis = local y
    w = 2 * reel_r + 2 * grow;  l = reel_hub_l() + 2 * grow;
    hull() for (sy = [-1, 1]) translate([0, sy * (l / 2 - w / 2)]) circle(d = w, $fn = 64);
}
reel_hollow = false;  // hub as a 2.4 mm shell with a 45-degree roof inside: measured slower (more perimeters)
module reel(cw, cl) {   // oval hub on the lid; the 45-degree flare's top is the pocket floor
    difference() {
        union() {
            translate([0, 0, lid_t - 0.01]) linear_extrude(reel_coil_h + 0.01) reel_2d(cw, cl);
            hull() {
                translate([0, 0, lid_t + reel_coil_h]) linear_extrude(0.5) reel_2d(cw, cl);
                translate([0, 0, lid_t + reel_coil_h + reel_flare]) linear_extrude(1.2) reel_2d(cw, cl, reel_flare);
            }
        }
        if (reel_hollow) let(wi = 2 * reel_r - 4.8, apex = lid_t + reel_h - 2.4, z0 = apex - wi / 2)
            hull() {
                translate([0, 0, -1]) linear_extrude(z0 + 1) reel_2d(cw, cl, -2.4);
                translate([0, 0, apex - 0.6]) linear_extrude(0.6)
                    hull() for (sy = [-1, 1]) translate([0, sy * (reel_hub_l() / 2 - reel_r)]) circle(d = 1.2, $fn = 16);
            }
    }
}
function probe_floor_z() = lid_t + (probe_reel ? reel_h : 0);
function reel_turn() = 2 * (reel_hub_l() - 2 * reel_r) + 2 * PI * (reel_r + 2.6);

// Debug Probe pockets: walls as high as the probe, a screwed-on cover per probe
// (part "probe_cover", print two; 2 x M3 x 8 self-tapping into the bosses beside it)
probe_pocket_h = probe[2] + 0.4 + (probe_snap ? snap_tooth + 0.6 : 0);
function probe_cw() = probe[0] + 0.6 + 3.6;
function probe_cl() = probe[1] + 0.6 + 3.6;
probe_y_front = probe_reel ? 0 : 1;   // pocket front: the JST leads drop into the front slot, and long straight
                     // micro-USB plugs at the back stay over the lid
function probe_cy0() = probe_y_front;
// pocket centre of probe i, and a point given in the pocket's own frame (y = long axis,
// micro-USB end at +y) mapped to the case
function probe_c(i) = probe_rot ? (probe_diag ? [[59.9, 14.5], [25.1, 58.5]][i] : [2 + probe_cl() / 2, [14.3, 70.9][i]])
                                : [probe_x(probe_cw())[i], probe_cy0() + probe_cl() / 2];
function probe_ang(i) = probe_rot ? ((probe_diag && i == 0) ? 90 : -90) : 0;
function probe_w(i, lx, ly) = let(a = probe_ang(i), c = probe_c(i))
    [c[0] + lx * cos(a) - ly * sin(a), c[1] + lx * sin(a) + ly * cos(a)];
module at_probe(i) { translate([probe_c(i)[0], probe_c(i)[1], 0]) rotate([0, 0, probe_ang(i)]) children(); }
function probe_screws(i = -1) = probe_snap ? [] : [for (k = [0, 1]) if (i < 0 || i == k) for (sd = [-1, 1])
    probe_w(k, sd * (probe_cw() / 2 + 3.25), 0)];
module probe_cover() {
    cw = probe_cw(); cl = probe_cl();
    difference() {
        hull() {
            translate([-cw / 2, 0, 0]) cube([cw, cl, 2]);
            for (sd = [-1, 1]) translate([sd * (cw / 2 + 3.25), cl / 2, 0]) cylinder(d = 7, h = 2);
        }
        for (sd = [-1, 1]) translate([sd * (cw / 2 + 3.25), cl / 2, -1]) cylinder(d = 3.4, h = 4);
    }
}
module probe_cover_labelled(i) {
    difference() { probe_cover(); translate([0, probe_cl() / 2, 1.4]) label(i == 0 ? "A" : "B", 10); }
}

lid_open_floor = true;
lid_vent_w    = 16;     // the lid's wall windows: wider, 4 mm piers
lid_vent_flat = true;   // plain rectangles; the bridge over each is only 16 mm
roof_vent = [10, 16];   // roof slot width, pitch
// roof over the enclosed top: vents, M3 x 10 from the top into the lid's nut blocks
module roof() {
    difference() {
        outline(roof_t);
        for (x = [6 : roof_vent[1] : bw - 6 - roof_vent[0]]) translate([x, 4, -1]) rrect(0, 0, roof_vent[0], bd - 8, 1.7, roof_t + 2);
        rod_holes();
        boss_recesses();
        for (p = posts) translate([p[0], p[1], roof_t - 1.5]) cylinder(d = 6.4, h = 10);
        translate([bw / 2, oy0 + ring / 2 - 1, roof_t - 0.6]) label("YasOS CI", 5);
    }
}

// Pi tier on its own: a flat cover on the base posts, fan grille over the Active
// Cooler, M3 screws from the top into the base nut traps
head_recess = 2;
pi_screw = base_t + h_pi + lid_t - head_recess - 0.5;
echo(str("pi_top: M3 x ", floor(pi_screw / 5) * 5, " socket-head screws (max ", pi_screw, " mm)"));
module pi_top() {
    difference() {
        outline(lid_t);
        for (x = [3 : 6.5 : bw - 6]) translate([x, 3, -1]) rrect(0, 0, 3.5, bd - 6, 1.6, lid_t + 2);
        translate([ix0 + 6, bd + 2, -1]) rrect(0, 0, ix1 - ix0 - 12, back_ch - 4, 2, lid_t + 2);
        rod_holes();
        boss_recesses();
        for (p = posts) translate([p[0], p[1], lid_t - head_recess]) cylinder(d = 6.4, h = 10);
        translate([bw / 2, -gap - ring / 2, lid_t - 0.6]) label("Raspberry Pi 5", 4.5);
    }
}

// lattice the Pi lies on, from the bed up to the old standoff height; the lines run
// out to the frame, the last cross line stops at the back channel
module pi_grid() {
    z0 = base_floor == "solid" ? base_t - 0.01 : 0;   // on the floor, or from the bed
    gh = base_t + so_h_pi - z0;
    x0 = pi_holes[0][0]; y0 = pi_holes[0][1];
    xs = [for (k = [-1 : 8]) x0 - pi_grid_p[0] / 2 + k * pi_grid_p[0]];
    ys = [for (k = [-1 : 5]) y0 - pi_grid_p[1] / 2 + k * pi_grid_p[1]];
    ymax = max([for (y = ys) if (y < bd + 3) y]);
    for (x = xs) if (x > ix0 && x < ix1)
        translate([x - pi_grid_rib / 2, iy0 - 1, z0]) cube([pi_grid_rib, ymax - iy0 + 1 + pi_grid_rib / 2, gh]);
    for (y = ys) if (y > iy0 && y <= ymax)
        translate([ix0 - 1, y - pi_grid_rib / 2, z0]) cube([ix1 - ix0 + 2, pi_grid_rib, gh]);
}

// Pi clamp, shaped _|-|_: feet on the base bosses, legs outside the board, a bridge
// over the HAT with pads on its standoff screws (the Pi's holes).  Built in the
// print frame (profile flat on the bed): X = case y, Y = case z above the bosses,
// Z = across the clamp.  Print two; M3 x 10 screws into the bosses.
clamp_z0 = base_t + clamp_boss_h;                // feet underside (case z)
clamp_zb = base_t + pi_stack_top - clamp_z0;     // pads underside (print Y)
clamp_top = clamp_zb + clamp_relief + clamp_t;
if (pi_clamps && base_t + pi_stack_top + clamp_relief + clamp_t > base_t + h_pi)
    echo("WARNING: the Pi clamps stick up into the next tier: raise h_pi");
module pi_clamp() {
    yl0 = clamp_yf + 3; yl1 = clamp_yb - 3;      // legs: inner faces of the feet
    difference() {
        linear_extrude(clamp_w) union() {
            translate([clamp_yf - 3, 0]) square([6, 3]);                       // feet
            translate([clamp_yb - 3, 0]) square([6, 3]);
            translate([yl0, 0]) square([3, clamp_top]);                        // legs
            translate([yl1 - 3, 0]) square([3, clamp_top]);
            translate([yl0, clamp_zb + clamp_relief]) square([yl1 - yl0, clamp_t]);   // bridge
            for (y = [pi_holes[0][1], pi_holes[2][1]])                         // pads
                translate([y - 4, clamp_zb]) square([8, clamp_relief + 0.01]);
        }
        for (y = [clamp_yf, clamp_yb])
            translate([y, -1, clamp_w / 2]) rotate([-90, 0, 0]) cylinder(d = 3.4, h = 5);
    }
}
module pi_clamp_in_case(cx) {
    translate([cx - clamp_w / 2, 0, clamp_z0])
        multmatrix([[0, 0, 1, 0], [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 0, 1]]) pi_clamp();
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
    color("orange", case_alpha) base();
    translate([0, 0, base_t + so_h_pi]) ghost_pi();
    color("teal", 0.6) translate([0, 0, base_t + pi_stack_top - 3.6]) cube([65, bd, 1.6]);   // NVMe HAT
    if (pi_clamps) for (cx = clamp_x) color("red") pi_clamp_in_case(cx);
    for (i = [0, 1]) {
        z = (i == 0 ? z_lane_a : z_lane_b) + (i + 1) * e;
        translate([0, 0, z]) color("orange", case_alpha) lane();
        translate([lane_dx, 0, z + plate_t + so_h_lane]) ghost_lane();
    }
    if (service_tier) {
        translate([0, 0, z_service + 3 * e]) color("orange", case_alpha) service();
        if (extra_tier == "reels") for (c = spool_c)
            color("royalblue", 0.5) translate([c[0], c[1], z_service + 3 * e + plate_t + 1])
                difference() { cylinder(d = spool_d + 8, h = 11); translate([0, 0, -1]) cylinder(d = spool_d, h = 13); }
        else translate([switch_origin[0], switch_origin[1], z_service + 3 * e + plate_t]) ghost_switch();
    }
    translate([0, 0, z_lid + (service_tier ? 4 : 3) * e]) color("orange", case_alpha) lid();
    if (top_closed) translate([0, 0, z_lid + lid_t + h_top + (service_tier ? 6 : 5) * e]) color("orange", case_alpha) roof();
    cw = probe[0] + 0.6 + 3.6;  cl = probe[1] + 0.6 + 3.6;
    for (i = [0, 1]) translate([0, 0, z_lid + (service_tier ? 4 : 3) * e + probe_floor_z()]) at_probe(i) {
        translate([-probe[0]/2, -cl/2 + 2.1, 0]) ghost_probe();
        if (!probe_snap) translate([0, -cl/2, probe_pocket_h + 0.5 * e]) color("orange", case_alpha) probe_cover_labelled(i);
    }
}

if (part == "assembly") assembly();
else if (part == "base") base();
else if (part == "lane") lane();
else if (part == "service") service();
else if (part == "lid") lid();
else if (part == "pi_top") pi_top();
else if (part == "roof") roof();
else if (part == "pi_clamp") pi_clamp();
else if (part == "probe_cover") probe_cover_labelled(0);
else if (part == "probe_cover_b") probe_cover_labelled(1);
