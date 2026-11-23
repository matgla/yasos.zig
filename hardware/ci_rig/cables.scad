// Illustration: cable routes for the CI rig (not printed).  openscad cables.scad
// USB (4): from 90-degree USB-A plugs in the Pi 5's ports, back along the right wall
// (zip ties), up the duct at the back right (slots in every tray, snap-in clips), out
// to the boards' 90-degree USB-C plugs and, through the lid, to the probes' micro-USB.
// JST (SWD + UART, per probe): down the 3 mm slot in front of the boards.
include <ci_rig.scad>
part = "none";
case_alpha = 0.35;
show = "all";   // [all, clash]: clash = only what cables and plugs share with printed parts
enclosed = false;   // open frame for the view; the clash check must run with -D enclosed=true
lintel_props = false;   // the break-away props come off after printing

function seglen(p, i) = norm(p[i + 1] - p[i]);
function pathlen(p) = [for (i = [0 : len(p) - 2]) 1] * [for (i = [0 : len(p) - 2]) seglen(p, i)];
module cable(p, d) { for (i = [0 : len(p) - 2]) hull() { translate(p[i]) sphere(d / 2, $fn = 10); translate(p[i + 1]) sphere(d / 2, $fn = 10); } }

usb_d = 4.2;  jst_d = 2.5;
pcb_top = base_t + so_h_pi + 1.6;
ports = [[27.5, pcb_top + 12], [44.5, pcb_top + 12], [27.5, pcb_top + 4], [44.5, pcb_top + 4]];  // MEASURE
// rear column (ports 1, 3): 90-degree USB-A plugs, leads straight back inside along the
// right wall; front column (ports 0, 2): straight plugs, leads fold back outside past
// the angled plugs and come in through the back cut-out next to the duct
plug_ang = [12, 14, 8];         // angled USB-A body: out of the port (x), along y, z
plug_str = [42, 16, 9];         // straight USB-A overmould outside the port (LINDY 36731: long)
micro_l  = 25;                  // straight micro-USB plug body + strain relief (keep it short: enclosed top)
rear = function(i) i % 2 == 1;
// which Pi port each lead uses: [probe A, probe B, board A, board B]; 0/2 front (upper/lower),
// 1/3 rear (upper/lower).  Default: both boards rear (2x LEWY angled USB-A <-> angled USB-C),
// both probes front (straight USB-A <-> micro-USB).
port_of = [0, 2, 1, 3];
pico_x = 36.5 + lane_dx;  lane_z = [z_lane_a, z_lane_b];
pico_top = function(z) z + plate_t + so_h_lane + 1.6 + 8.5 + 1;
plug_c = [10, 11, 9];           // 90-degree (down) USB-C plug body: x, y (from the board edge), z
cw = probe[0] + 0.6 + 3.6;  cl = probe[1] + 0.6 + 3.6;  px = probe_x(cw);
probe_z = z_lid + probe_floor_z() + probe[2] / 2;
probe_y0 = probe_cy0() + 2.1;  probe_y1 = probe_y0 + probe[1];
duct_y = (duct[2] + duct[3]) / 2;
dx = [for (k = [0 : 3]) duct[1] - 18.5 + 5 * k];   // lead positions: the right part of the duct, clear of the Pi clamp
port_x = bw + 2.5;
low_z = base_t + 9;

// spare cable: one loop each, parallel to the back wall behind the Pi (slack_r = 0: none)
slack_r = 10;   // two columns of two loops, in front of the Pi clamps' back legs (y < 67)
function loop(i) = let(y = bd + 2.6 + 4.6 * (i % 2), cx = 20 + 24 * floor(i / 2), cz = base_t + so_h_pi + 6 + slack_r)
    [for (a = [-90 : 30 : 270]) [cx + slack_r * cos(a), y, cz + slack_r * sin(a)]];
function lead_in(i) = rear(i)
    ? [[bw + 5, ports[i][0] + plug_ang[1] / 2, ports[i][1]], [bw + 5, ports[i][0] + 12, ports[i][1]],
       [bw + 5, 63, low_z + (i == 1 ? 3 : 0)]]
    // straight plugs: through the port mask, a loop outside past the angled plugs, then in
    // through the leads' own opening behind the ports
    : let(zt = base_t + so_h_pi + 12 + 4 * i / 2, yo = 63)
      [[port_x + plug_str[0], ports[i][0], ports[i][1]], [port_x + plug_str[0] + 8, ports[i][0] + 3, ports[i][1] + 3],
       [port_x + plug_str[0] + 8, ports[i][0] + 9, zt], [bw + 20, yo, zt], [bw + 4, yo, zt],
       [76 + 4 * i / 2, bd + 8, low_z + 4 * i / 2]];
// spare loops behind the Pi only for the boards' leads; the probes' spare lead goes on the reels
has_loop = function(i) slack_r > 0 && (i == port_of[2] || i == port_of[3]);
function base_run(i) = concat(lead_in(i), has_loop(i) ? loop(i) : [],
                        [[dx[i], 63, low_z + 2 * (i % 2)], [dx[i], duct_y, low_z + 2 * (i % 2)]]);
function usb_board(l) = concat(base_run(port_of[2 + l]), [
    [dx[port_of[2 + l]], duct_y, lane_z[l] + plate_t + duct_h + 2], [(duct[0] + duct[1]) / 2, duct[2] - 3, lane_z[l] + plate_t + duct_h + 2],
    [pico_x, bd + plug_c[1] / 2, lane_z[l] + plate_t + duct_h + 2], [pico_x, bd + plug_c[1] / 2, pico_top(lane_z[l]) - plug_c[2] / 2]]);
// probes: up the duct to the reel tier, turns round a spool, back to the duct, up to the probe
reel_turns = 3;   // a 1 m lead leaves ~3-4 turns
function coil(l) = let(sc = spool_c[l], r = spool_d / 2 + 2.6, z0 = z_service + plate_t + 2.5)
    [for (a = [0 : 10 : 360 * reel_turns]) [sc[0] + r * cos(a + 90), sc[1] + r * sin(a + 90), z0 + 3.7 * a / 360]];
// probe_reel: the spare lead winds round the spool under the probe (rounded rectangle)
function rr_loop(w, l, r) = [for (k = [0 : 3]) let(sx = (k == 0 || k == 3) ? 1 : -1, sy = k < 2 ? 1 : -1)
    for (a = [90 * k : 10 : 90 * k + 90]) [sx * (w / 2 - r) + r * cos(a), sy * (l / 2 - r) + r * sin(a)]];
// starts on the right of the spool, ends at the back after reel_turns turns
function reel_coil(l) = let(lp = rr_loop(2 * (reel_r + 2.6), reel_hub_l() + 5.2, reel_r + 2.6),
                            n = len(lp), z0 = z_lid + lid_t + 2.5)
    let(k0 = probe_rot ? ((probe_diag && l == 0) ? 29 : 9) : (l == 0 ? 0 : n / 2 - 1),
        // rotated: start at the side facing the lead coming in (A, diagonal: its JST end, by the right
        // wall), end at the micro-USB end; side by side: start at the gap, end at the back
        e = probe_rot ? ((9 - k0) % n + n) % n : ((n / 4 - k0) % n + n) % n)
    [for (k = [0 : reel_turns * n + e]) let(p = lp[(k + k0) % n], w = probe_w(l, p[0], p[1]))
        [w[0], w[1], z0 + 3.7 * k / n]];
reel_w = 2 * (reel_r + 2.6);  reel_l = reel_hub_l() + 5.2;
function reel_in(l) = let(z = z_lid + lid_t + 2.5, st = reel_coil(l)[0])
    probe_rot ? (probe_diag ? (l == 0 ? [[bw + 8.5, bd + 4, z], [bw + 8.5, st[1], z], [st[0] + 4, st[1], z]]
                                      : [[60, bd + 12, z], [st[0] + 4, st[1], z]])
                            : [[60, l == 0 ? 40 : 82, z], [st[0] + 4, st[1], z]])
              : let(cy = probe_c(l)[1], gap_x = (px[0] + px[1]) / 2)
                [[gap_x, bd + 3, z], [gap_x, cy + reel_l / 2 - reel_r - 2.6, z]];
micro_end = function(l) probe_w(l, 0, -probe_cl() / 2 + 2.1 + probe[1] + micro_l);
function usb_probe(l) = probe_reel
  ? concat(base_run(port_of[l]), [[dx[port_of[l]], duct_y, z_lid + lid_t + 3]], reel_in(l), reel_coil(l),
           probe_rot ? [[micro_end(l)[0], micro_end(l)[1], probe_z]]
                     : [[px[l], probe_cy0() + probe_cl() / 2 + reel_l / 2 + 6, z_lid + lid_t + 2.5 + 3.7 * (reel_turns + 0.8)],
                        [px[l], probe_y1 + micro_l, probe_z]])
  : concat(base_run(port_of[l]),
    service_tier && extra_tier == "reels"
      ? concat([[dx[port_of[l]], duct_y, z_service + plate_t + duct_h + 2.5], [dx[port_of[l]], duct[2] - 5, z_service + plate_t + duct_h + 2.5],
                [spool_c[l][0], spool_c[l][1] + spool_d / 2 + 2.6, z_service + plate_t + 2.5]],
               coil(l),
               [[dx[port_of[l]], duct[2] - 5, z_service + plate_t + duct_h + 5], [dx[port_of[l]], duct_y, z_service + plate_t + duct_h + 5]])
      : [],
    [[dx[port_of[l]], duct_y, z_lid + lid_t + 2], [px[l], probe_y1 + micro_l, probe_z]]);
jst_y = (jst_slot_y[0] + jst_slot_y[1]) / 2;
function jst_drop(l) = probe_rot ? let(r = jst_slots_l[l]) [(r[0] + r[1]) / 2, (r[2] + r[3]) / 2] : [px[l], jst_y];
function jst_start(l) = probe_rot ? probe_w(l, 0, -probe_cl() / 2 + 2.1 - 4) : [px[l], probe_y0 - 2];
function jst(l) = [[jst_start(l)[0], jst_start(l)[1], probe_z], [jst_drop(l)[0], jst_drop(l)[1], probe_z + 2],
                   [jst_drop(l)[0], jst_drop(l)[1], z_lid + lid_t],
                   [jst_drop(l)[0] + (probe_rot ? 0 : 3 * l), jst_drop(l)[1], pico_top(lane_z[l]) + 14], [pico_x, 6, pico_top(lane_z[l]) + 8],
                   [pico_x, 6, pico_top(lane_z[l]) + 4.5]];
module pi_plug(i) {
    p = rear(i) ? plug_ang : plug_str;
    translate([port_x, ports[i][0] - p[1] / 2, ports[i][1] - p[2] / 2]) cube(p);
}
module plugs() {
    if (power_gutter) power_plug();
    for (i = [0 : 3]) pi_plug(i);
    for (l = [0, 1]) translate([pico_x - plug_c[0] / 2, bd - 1, pico_top(lane_z[l]) + 1.6 - plug_c[2] / 2]) cube(plug_c);
    for (l = [0, 1]) translate([0, 0, probe_z - 3.5]) at_probe(l)
        translate([-5, -probe_cl() / 2 + 2.1 + probe[1], 0]) cube([10, micro_l, 7]);   // micro-USB
}
// Pi power: 90-degree USB-C (cable to the right) at x 11.2 on the Pi's front edge, along the
// front inside, out through the front cut-out into the gutter, to the right-front corner
pwr_d = 5;
pwr_z = pcb_top + 1.6;
pwr_plug = [12, 12, 8];   // body: x, y (out from the receptacle), z
function power_lead() = [[11.2 + pwr_plug[0] / 2, -1 - pwr_plug[1] / 2, pwr_z], [40, -1 - pwr_plug[1] / 2, pwr_z],
    [47, oy0 - 4, base_t + pwr_d / 2 + 0.3], [ox1 - 2, oy0 - 4, base_t + pwr_d / 2 + 0.3],
    [ox1 + 8, oy0 + 2, base_t + pwr_d / 2 + 0.3]];
module power_plug() { translate([11.2 - pwr_plug[0] / 2, -1 - pwr_plug[1], pwr_z - pwr_plug[2] / 2]) cube(pwr_plug); }
module all_cables() {
    if (power_gutter) cable(power_lead(), pwr_d);
    for (l = [0, 1]) { cable(usb_board(l), usb_d); cable(usb_probe(l), usb_d); cable(jst(l), jst_d); }
}
module printed() {
    base();
    for (cx = clamp_x) pi_clamp_in_case(cx);
    // the boards themselves (PCB slabs, Pi with HAT, VGA bases with the Pico on headers)
    translate([0, 0, base_t + so_h_pi]) cube([bw, bd, 1.6]);
    translate([0, 0, base_t + pi_stack_top - 3.6]) cube([65, bd, 1.6]);
    for (z = lane_z) translate([lane_dx, 0, z + plate_t + so_h_lane]) {
        cube([bw, bd, 1.6]);
        translate([26, 3, 0]) cube([21, 51, 11.1]);
    }
    for (z = lane_z) translate([0, 0, z]) lane();
    if (service_tier) translate([0, 0, z_service]) service();
    translate([0, 0, z_lid]) lid();
    if (!probe_snap) for (i = [0, 1]) translate([0, 0, z_lid + probe_floor_z() + probe_pocket_h]) at_probe(i) translate([0, -probe_cl() / 2, 0]) probe_cover();
    if (top_closed) translate([0, 0, z_lid + lid_t + h_top]) roof();
}

if (show == "none" || show == "plugclash") {} else if (show == "clash") intersection() { printed(); union() { all_cables(); plugs(); } }
else {
    assembly();
    for (l = [0, 1]) {
        color(l == 0 ? "gold" : "orange") cable(usb_board(l), usb_d);
        color(l == 0 ? "deepskyblue" : "royalblue") cable(usb_probe(l), usb_d);
        color(l == 0 ? "lime" : "green") cable(jst(l), jst_d);
    }
    if (power_gutter) color("red") cable(power_lead(), pwr_d);
    color("dimgray") plugs();
}
for (l = [0, 1]) echo(str("lane ", l == 0 ? "A" : "B", ": board USB ", round(pathlen(usb_board(l))),
    " mm, probe USB ", round(pathlen(usb_probe(l))), " mm, JST ", round(pathlen(jst(l))), " mm (between plug bodies)"));
echo(str("each spare loop holds ", round(2 * PI * slack_r), " mm"));
if (service_tier && extra_tier == "reels")
    echo(str("each reel as drawn holds ", round(reel_turns * PI * (spool_d + 5.2)), " mm"));
// Pi-side leads against the other ports' plugs (show = "plugclash")
if (show == "plugclash") for (i = [0 : 3]) intersection() {
    cable(base_run(i), usb_d);
    for (j = [0 : 3]) if (j != i) pi_plug(j);
}
