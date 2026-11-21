// Scadretto acceptance fixture — keep this comment.
$fn = 64;
hole_d = 4;
count = 4;
pitch = 20;
x0 = 15;
plate_h = 6;

module mounting_hole(d) {
    cylinder(h = plate_h + 2, d = d);
}

difference() {
    cube([120, 40, plate_h]);
    for (i = [0 : count - 1])
        translate([x0 + i * pitch, 20, -1])
            mounting_hole(d = hole_d);
}
