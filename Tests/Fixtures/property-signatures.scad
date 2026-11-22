// The positions separate the solids so the reference can compare the full fixture.
$fn = 16;
cube([4, 6, 8], center = true);
translate([10, 0]) sphere(r = 2);
translate([20, 0, 0]) cylinder(8, 2);
translate([30, 0, 0]) cylinder(h = 8, 2);
translate([40, 0, 0]) cylinder(8, 2, 3, false, 5);
translate([50, 0, 0]) cylinder(d = 8, r = 1);
translate([60, 0, 0]) cylinder(r = 2, r2 = 4);
translate([70, 0, 0]) cylinder(8, 2, h = 7);
translate([85, 0, 0]) cylinder(3, 2, 3, false, 4, 6, 8, 10, 1);
translate([100, 0, 0]) translate(5) cube(3);
translate([110, 0, 0]) sphere(d = 4, $fn = 12);
translate([125, 0, 0]) translate([-3, 0, 0]) cube(2);
