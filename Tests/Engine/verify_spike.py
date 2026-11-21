"""Exercise the patched evaluator and the stock CLI on real engine meshes."""

import argparse
import collections
import hashlib
import json
import math
from pathlib import Path
import statistics
import struct
import subprocess
import time


PLATE_DIGEST = "136c95090096979a91024b7f1e6325f4f09fdca421880d6ffee447ac6c095235"
BOM = b"\xef\xbb\xbf"
BOUND_TOLERANCE = 1e-4
VOLUME_REL_TOLERANCE = 1e-5
DIFFERENCE_ABS_TOLERANCE = 0.01
DIFFERENCE_REL_TOLERANCE = 1e-6


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def subtract(a, b):
    return tuple(x - y for x, y in zip(a, b))


def add_scaled(a, b, scale):
    return tuple(x + y * scale for x, y in zip(a, b))


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def cross(a, b):
    x, y, z = a
    u, v, w = b
    return y * w - z * v, z * u - x * w, x * v - y * u


def normalize(vector):
    return tuple(x / math.hypot(*vector) for x in vector)


def facets(mesh):
    return [
        tuple(mesh["vertices"][i] for i in face)
        for face in mesh["triangles"]
    ]


def ray_hits(triangles, origin, direction):
    hits = []
    for index, (a, b, c) in enumerate(triangles):
        ab, ac = subtract(b, a), subtract(c, a)
        perpendicular = cross(direction, ac)
        determinant = dot(ab, perpendicular)
        if abs(determinant) < 1e-12:
            continue
        offset = subtract(origin, a)
        u = dot(offset, perpendicular) / determinant
        perpendicular = cross(offset, ab)
        v = dot(direction, perpendicular) / determinant
        distance = dot(ac, perpendicular) / determinant
        if u >= -1e-9 and v >= -1e-9 and u + v <= 1 + 1e-9 and distance >= 0:
            hits.append((distance, index, normalize(cross(ab, ac))))
    return sorted(hits)


def bounds(mesh):
    columns = tuple(zip(*mesh["vertices"]))
    return [list(map(min, columns)), list(map(max, columns))]


def volume(mesh):
    return math.fsum(dot(a, cross(b, c)) / 6 for a, b, c in facets(mesh))


def check_closed(mesh):
    edges = collections.Counter()
    vertices = mesh["vertices"]
    check(all(len(p) == 3 and all(math.isfinite(x) for x in p) for p in vertices),
          "Mesh contains invalid vertices")
    for face in mesh["triangles"]:
        check(len(set(face)) == len(face) == 3 and all(0 <= i < len(vertices) for i in face),
              f"Invalid triangle {face}")
        a, b, c = (vertices[i] for i in face)
        check(math.hypot(*cross(subtract(b, a), subtract(c, a))) > 0, "Degenerate face")
        edges.update(zip(face, (*face[1:], face[0])))
    check(edges and all(count == 1 and edges[b, a] == 1 for (a, b), count in edges.items()),
          "Mesh is open, inconsistently wound or nonmanifold")


def read_binary_stl(path):
    raw = path.read_bytes()
    (count,) = struct.unpack_from("<I", raw, 80)
    check(len(raw) == 84 + count * 50, f"Truncated STL {path}")
    points = {}
    triangles = []
    for record in struct.iter_unpack("<12fH", raw[84:]):
        # OpenSCAD writes identical coordinates as the same float32 tuple.
        # Weld duplicates exactly so near-parallel features stay distinct.
        triangles.append([points.setdefault(record[i:i + 3], len(points)) for i in (3, 6, 9)])
    return {"vertices": list(points), "triangles": triangles}


def write_off(path, mesh):
    with path.open("w", encoding="ascii") as output:
        print("OFF", file=output)
        print(len(mesh["vertices"]), len(mesh["triangles"]), 0, file=output)
        for point in mesh["vertices"]:
            print(*point, file=output)
        for face in mesh["triangles"]:
            print(3, *face, file=output)


def run(executable, arguments, environment, log):
    start = time.perf_counter()
    process = subprocess.run([executable, *arguments], env=environment, cwd=log.parent,
                             check=False, capture_output=True, timeout=30)
    elapsed = time.perf_counter() - start
    log.write_bytes(process.stdout + process.stderr)
    return process, elapsed * 1000


def worker_job(worker, directory, source, logical_path, env):
    directory.mkdir(mode=0o700, exist_ok=True)
    (directory / "main.scad").write_bytes(source)
    request = directory / "request.json"
    request.write_text(json.dumps({"logicalPath": str(logical_path), "snapshot": "main.scad"}))
    result_path = directory / "result.json"
    result_path.unlink(missing_ok=True)
    process, elapsed = run(worker, ["--scadretto-job", request], env, directory / "worker.log")
    check(process.returncode == 0 and result_path.is_file(), f"Worker failed in {directory}")
    result = json.loads(result_path.read_bytes())
    check(result["status"] == "ok", result)
    check(result["sourceByteLength"] == len(source), "Wrong source byte length")
    check(result["sourceSHA256"] == hashlib.sha256(source).hexdigest(), "Wrong source digest")
    check(result["bomBytes"] == (3 if source.startswith(BOM) else 0), "Wrong BOM length")
    return result, elapsed


def render_reference(reference, source, output, env):
    process, _ = run(reference, ["--backend=manifold", "--export-format=binstl", "-o", output, source],
                     env, output.with_suffix(".log"))
    check(process.returncode == 0 and output.is_file(), f"Reference failed for {source}")
    return read_binary_stl(output)


def symmetric_difference(oracle, working, mesh, reference):
    check_closed(mesh)
    check_closed(reference)
    worker_off, ref_off = working / "worker.off", working / "reference.off"
    write_off(worker_off, mesh)
    write_off(ref_off, reference)
    result = subprocess.run([oracle, worker_off, ref_off], check=True, capture_output=True, timeout=30)
    return float(result.stdout)


def measure_plate(mesh, count, diameter, pitch):
    for measured, expected in zip(bounds(mesh), [[0, 0, 0], [120, 40, 6]]):
        check(all(abs(a - b) <= BOUND_TOLERANCE for a, b in zip(measured, expected)),
              f"Unexpected plate bounds {bounds(mesh)}")
    expected = 28800 - count * 6 * 32 * (diameter / 2) ** 2 * math.sin(2 * math.pi / 64)
    actual = volume(mesh)
    check(math.isclose(actual, expected, rel_tol=VOLUME_REL_TOLERANCE),
          f"Plate volume {actual} differs from expected {expected}")

    triangles = facets(mesh)
    for index in range(count):
        center = 15 + index * pitch
        check(not ray_hits(triangles, (center, 20, 9), (0, 0, -1)), f"Bore {index} is blocked")
        check(len(ray_hits(triangles, (center + 3, 20.27, 9), (0, 0, -1))) == 2,
              f"Missing solid next to bore {index}")
    check(not ray_hits(triangles, (-1, 20, 9), (0, 0, -1)), "Solid outside plate")
    return actual


def transform_point(matrix, point):
    return tuple(sum(matrix[4 * j + i] * point[j] for j in range(3)) + matrix[12 + i]
                 for i in range(3))


def covers_point(triangle, point, normal, tolerance):
    a, b, c = triangle
    surface_normal = normalize(cross(subtract(b, a), subtract(c, a)))
    # A subtracting surface faces the opposite way from the operand.
    if abs(dot(surface_normal, normal)) < 0.99999:
        return False
    if abs(dot(subtract(point, a), surface_normal)) > tolerance:
        return False
    for start, end in ((a, b), (b, c), (c, a)):
        edge = subtract(end, start)
        distance = dot(cross(edge, subtract(point, start)), surface_normal) / math.hypot(*edge)
        if distance < -tolerance:
            return False
    return True


def candidates(operands, point, normal, tolerance):
    result = set()
    for owner, triangles in operands.items():
        if any(covers_point(t, point, normal, tolerance) for t in triangles):
            result.add(owner)
    return result


def verify_binding(node, raw, file, expected_span, expected_value):
    diameter = node["diameter"]
    check(diameter["value"] == expected_value, "Wrong cylinder diameter")
    chain = diameter["chain"]
    check(chain[0]["kind"] == "parameter" and chain[0]["name"] == "d", "Missing formal binding")
    check([step["name"] for step in chain if step["kind"] == "lookup"] == ["d", "hole_d"],
          "Lookup chain skipped a scope")
    check(chain[-2]["kind"] == "assignment" and chain[-2]["name"] == "hole_d",
          "Wrong resolved assignment")
    check(chain[-1]["kind"] == "literal", "Binding chain did not reach a literal")
    for step in chain:
        span = step["span"]
        check(span is not None and span["file"] == str(file), f"Wrong logical file for {step}")
        check(0 <= span["start"] < span["end"] <= len(raw), f"Invalid source span {span}")
    literal = chain[-1]["span"]
    start, end = literal["start"], literal["end"]
    check((start, end) == expected_span, "Wrong source span")
    check(raw[start:end] == str(expected_value).encode("ascii"), "Wrong source bytes")
    return [{**step, "text": raw[step["span"]["start"]:step["span"]["end"]].decode("utf-8")}
            for step in chain]


def verify_pick(result, raw, logical_path):
    nodes = {node["id"]: node for node in result["instances"]}
    cutters = sorted([node for node in nodes.values() if node["name"] == "cylinder"],
                     key=lambda node: node["iteration"]["i"])
    check([node["iteration"]["i"] for node in cutters] == [0, 1, 2, 3], "Wrong loop occurrences")
    check(len({node["operand"] for node in cutters}) == 1 and cutters[2]["operand"] is not None,
          "Equal cutters should share their cached local geometry")
    for cutter, expected_x in zip(cutters, [15, 35, 55, 75]):
        module = nodes[cutter["parent"]]
        translation = nodes[module["parent"]]
        check(module["name"] == "mounting_hole" and translation["name"] == "translate",
              "Missing executed call path")
        check(cutter["local"][12:15] == [0, 0, 0]
              and cutter["world"][12:15] == [expected_x, 20, -1], "Wrong instance transforms")
        verify_binding(cutter, raw, logical_path, (74, 75), 4)

    final_triangles = facets(result["mesh"])
    origin = (55, 20, 3)
    ray = (math.cos(0.041), math.sin(0.041), 0)
    hits = ray_hits(final_triangles, origin, ray)
    check(hits, "Expected a final inner-wall hit")
    distance, triangle, normal = hits[0]
    point = add_scaled(origin, ray, distance)
    check(1.99 < distance < 2 and dot(ray, normal) < -0.99, "Ray missed the cutter-facing wall")
    low, high = bounds(result["mesh"])
    tolerance = max(1e-9, min(1e-5, math.dist(low, high) * 1e-8))

    operands = {
        node["id"]: [
            tuple(transform_point(node["world"], vertex) for vertex in face)
            for face in facets(result["operands"][node["operand"]])
        ]
        for node in nodes.values() if node["operand"] is not None
    }
    owners = candidates(operands, point, normal, tolerance)
    check(owners == {cutters[2]["id"]}, f"Unexpected inner wall owners {owners}")

    # Approach the same wall facet at its intersection with the top plate.
    # Both sets of final triangle normals need to participate.
    from_above = (55, 20, 9)
    rim = (point[0], point[1], 6)
    rim_ray = normalize(subtract(rim, from_above))
    rim_hits = ray_hits(final_triangles, from_above, rim_ray)
    check(rim_hits and math.dist(add_scaled(from_above, rim_ray, rim_hits[0][0]), rim) <= tolerance,
          "First visible hit was not the rim")
    rim_owners = set().union(*(
        candidates(operands, rim, hit_normal, tolerance)
        for hit_distance, _, hit_normal in rim_hits
        if abs(hit_distance - rim_hits[0][0]) <= tolerance
    ))
    base = next(node for node in nodes.values() if node["name"] == "cube")
    check(rim_owners == {base["id"], cutters[2]["id"]}, f"Expected rim ambiguity, got {rim_owners}")

    chain = verify_binding(cutters[2], raw, logical_path, (74, 75), 4)
    return {"origin": origin, "direction": ray, "distance": distance, "triangle": triangle,
            "point": point, "normal": normal, "tolerance": tolerance, "owner": cutters[2]["id"],
            "iteration": cutters[2]["iteration"], "chain": chain, "rimCandidates": sorted(rim_owners)}


def verify_small_surfaces():
    triangle = ((0., 0., 0.), (1e-4, 0., 0.), (0., 1e-4, 0.))
    nearby = tuple((x, y, z + 4e-9) for x, y, z in triangle)
    point = (2e-5, 2e-5, 0.)
    check(candidates({1: [triangle], 2: [nearby]}, point, (0., 0., -1.), 1e-9) == {1},
          "Small parallel walls were conflated")


def verify(args):
    base = args.evidence.resolve()
    base.mkdir(parents=True, exist_ok=True)
    paths = {name: base / name for name in ("home", "tmp", "cache", "logical model café")}
    for directory in paths.values():
        directory.mkdir(exist_ok=True)
    environment = {"PATH": "/usr/bin:/bin", "HOME": str(paths["home"]), "TMPDIR": str(paths["tmp"]),
                   "XDG_CACHE_HOME": str(paths["cache"]), "LANG": "en_US.UTF-8", "LC_NUMERIC": "C"}
    logical = paths["logical model café"] / "plate.scad"
    logical.write_bytes(b"cube(1);\n")

    original = args.fixture.read_bytes()
    check(len(original) == 350 and hashlib.sha256(original).hexdigest() == PLATE_DIGEST,
          "Canonical fixture bytes changed")
    check((original[74:75], original[85:86], original[96:98]) == (b"4", b"4", b"20"),
          "Canonical fixture declaration spans changed")

    modified_diameter = original.replace(b"hole_d = 4;", b"hole_d = 5;")
    variants = [
        ("plate", original, 4, 4, 20),
        ("diameter", modified_diameter, 4, 5, 20),
        ("count", modified_diameter.replace(b"count = 4;", b"count = 5;"), 5, 5, 20),
        ("pitch", original.replace(b"pitch = 20;", b"pitch = 22;"), 4, 4, 22),
    ]
    evidence = {"geometry": {}}
    for name, raw, count, diameter, pitch in variants:
        folder = base / name
        result, ms = worker_job(args.worker, folder, raw, logical, environment)
        saved = folder / "saved.scad"
        saved.write_bytes(raw)
        ref = render_reference(args.reference, saved, folder / "reference.stl", environment)
        worker_volume = measure_plate(result["mesh"], count, diameter, pitch)
        reference_volume = measure_plate(ref, count, diameter, pitch)
        mismatch = symmetric_difference(args.oracle, folder, result["mesh"], ref)
        check(mismatch <= min(DIFFERENCE_ABS_TOLERANCE, worker_volume * DIFFERENCE_REL_TOLERANCE),
              f"{name}: symmetric-difference volume {mismatch}")
        evidence["geometry"][name] = {"workerVolume": worker_volume, "referenceVolume": reference_volume,
                                      "symmetricDifferenceVolume": mismatch, "workerMilliseconds": ms}
        if name == "plate":
            evidence["pick"] = verify_pick(result, raw, logical)
            baseline_mesh = result["mesh"]

    # Equal bounds and volume, and the same fixed inside/outside probes.
    folder = base / "shifted-bore"
    folder.mkdir(exist_ok=True)
    shifted = folder / "shifted.scad"
    shifted.write_bytes(original.replace(b"20, -1]", b"20 + (i == 2 ? 0.75 : 0), -1]"))
    shifted_mesh = render_reference(args.reference, shifted, folder / "shifted.stl", environment)
    measure_plate(shifted_mesh, 4, 4, 20)
    mismatch = symmetric_difference(args.oracle, folder, baseline_mesh, shifted_mesh)
    check(mismatch > 10, "Oracle accepted an equal-volume displaced bore")
    evidence["displacedBoreDifference"] = mismatch
    invalid = folder / "open.off"
    write_off(invalid, {**baseline_mesh, "triangles": baseline_mesh["triangles"][1:]})
    bad = subprocess.run([args.oracle, invalid, folder / "reference.off"],
                         capture_output=True, timeout=30)
    check(bad.returncode == 1, "Oracle accepted an open mesh")
    verify_small_surfaces()

    patched_cli = render_reference(args.worker, base / "plate/saved.scad", base / "patched-cli.stl", environment)
    check(symmetric_difference(args.oracle, base, baseline_mesh, patched_cli)
          <= DIFFERENCE_ABS_TOLERANCE, "Ordinary patched CLI geometry differs")

    bom_result, _ = worker_job(args.worker, base / "bom-plate", BOM + original, logical, environment)
    bom_cutters = [node for node in bom_result["instances"] if node["diameter"]]
    check(len(bom_cutters) == 4, "BOM changed runtime occurrences")
    for node in bom_cutters:
        verify_binding(node, BOM + original, logical, (77, 78), 4)
    bom_saved = base / "bom-plate/reference.scad"
    bom_saved.write_bytes(BOM + original)
    bom_ref = render_reference(args.reference, bom_saved, base / "bom-plate/reference.stl", environment)
    check(symmetric_difference(args.oracle, base / "bom-plate", bom_result["mesh"], bom_ref)
          <= DIFFERENCE_ABS_TOLERANCE, "Reference did not accept the BOM")
    inline = BOM + b"hole_d=4; cylinder(d=hole_d,h=1);\n"
    result, _ = worker_job(args.worker, base / "bom-inline", inline, logical, environment)
    inline_span = next(node for node in result["instances"] if node["diameter"])["diameter"]["chain"][-1]["span"]
    check((inline_span["start"], inline_span["end"]) == (10, 11), "First-line BOM byte offsets")

    equal = original + b"\ntranslate([130,0,0]) cylinder(h=8,d=4);\n"
    equal_result, _ = worker_job(args.worker, base / "equal-literal", equal, logical, environment)
    unrelated = [node for node in equal_result["instances"] if node["diameter"] and not node["iteration"]]
    check(len(unrelated) == 1, "Missing unrelated equal-valued cylinder")
    cut = unrelated[0]["diameter"]["chain"][-1]["span"]
    check(cut["start"] > len(original) and equal[cut["start"]:cut["end"]] == b"4",
          "Unrelated equal value incorrectly bound to hole_d")

    # The resolved input includes an import one directory below the included source.
    library = logical.parent / "parts"
    assets = library / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    asset_source = assets / "base.scad"
    asset_source.write_bytes(b"cube([2,3,4]);\n")
    render_reference(args.reference, asset_source, assets / "base.stl", environment)
    (library / "nested.scad").write_bytes(b'module piece() { import("assets/base.stl"); }\n')
    for directive in ("include", "use"):
        dependency = f"{directive} <parts/nested.scad>\npiece();\n".encode("ascii")
        folder = base / f"relative-import-{directive}"
        dependency_result, _ = worker_job(args.worker, folder, dependency, logical, environment)
        dependency_saved = logical.parent / "reference.scad"
        dependency_saved.write_bytes(dependency)
        ref_dependency = render_reference(args.reference, dependency_saved,
                                          folder / "dependency.stl", environment)
        check(volume(ref_dependency) == 24, "Reference did not load nested relative asset")
        check(symmetric_difference(args.oracle, folder, dependency_result["mesh"],
                                   ref_dependency) < 1e-8, f"Nested asset differs with {directive}")

    preview = b"if ($preview) cube(3); else cube(2);\n"
    result, _ = worker_job(args.worker, base / "preview", preview, logical, environment)
    check(volume(result["mesh"]) == 8, "Worker did not use final-render semantics")

    times = [worker_job(args.worker, base / "timing", original, logical, environment)[1] for _ in range(31)]
    evidence["workerTiming"] = {"firstMilliseconds": times[0], "warmMilliseconds": times[1:],
                                "warmP50": statistics.median(times[1:]), "warmP95": sorted(times[1:])[28]}
    font_times = {}
    for label, source in (
        ("default", b'linear_extrude(1) text("Scadretto");\n'),
        ("named", b'linear_extrude(1) text("Scadretto", font="Liberation Sans");\n'),
    ):
        folder = base / f"text-{label}"
        isolate = {**environment, "XDG_CACHE_HOME": str(folder / "cache")}
        result, cold = worker_job(args.worker, folder, source, logical, isolate)
        _, warm = worker_job(args.worker, folder, source, logical, isolate)
        (folder / "text.scad").write_bytes(source)
        ref = render_reference(args.reference, folder / "text.scad", folder / "text.stl", isolate)
        mismatch = symmetric_difference(args.oracle, folder, result["mesh"], ref)
        check(mismatch < min(DIFFERENCE_ABS_TOLERANCE, volume(result["mesh"]) * DIFFERENCE_REL_TOLERANCE),
              f"Pinned {label} font text geometry differs ({mismatch})")
        font_times[label] = {"firstMilliseconds": cold, "warmMilliseconds": warm, "difference": mismatch}
    evidence["textTiming"] = font_times
    if args.font_cache is not None:
        font_dir = args.fonts.resolve()
        cache_dir = base / "font-cache"
        cache_dir.mkdir()
        isolate = {**environment, "FONTCONFIG_PATH": str(font_dir),
                   "FONTCONFIG_FILE": str(font_dir / "fonts.conf"), "XDG_CACHE_HOME": str(cache_dir)}
        cached, elapsed = run(args.font_cache, ["--verbose"], isolate, base / "font-cache.log")
        check(cached.returncode == 0 and any(cache_dir.rglob("*.cache-*")), "Font cache did not build")
        evidence["coldFontCacheMilliseconds"] = elapsed

    (base / "spike-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for parameter in ("reference", "worker", "oracle", "fixture", "evidence"):
        parser.add_argument(parameter, type=lambda path: Path(path).resolve())
    parser.add_argument("--font-cache", type=Path)
    parser.add_argument("--fonts", type=Path)
    args = parser.parse_args()
    if (args.font_cache is None) != (args.fonts is None):
        parser.error("--font-cache and --fonts must be provided together")
    verify(args)


if __name__ == "__main__":
    main()
