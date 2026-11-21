// Scadretto stress fixture — 100 through-holes on a larger plate.
// Keep in sync with the stress workload in plan/06-Verification-and-Release.md.
$fn = 32;
hole_d = 4;
count = 100;
pitch = 20;
x0 = 15;
plate_h = 6;
plate_w = 2010;
plate_d = 40;

module mounting_hole(d) {
    cylinder(h = plate_h + 2, d = d);
}

difference() {
    cube([plate_w, plate_d, plate_h]);
    for (i = [0 : count - 1])
        translate([x0 + i * pitch, 20, -1])
            mounting_hole(d = hole_d);
}
