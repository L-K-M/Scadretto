#!/usr/bin/env python3
"""Run real v1 worker jobs and compare the portable protocol examples."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time

from verify_spike import check, render_reference, symmetric_difference

PROTOCOL = 1
FIXED_DOCUMENT = "00000000-0000-0000-0000-000000000001"
FIXED_REQUEST = "00000000-0000-0000-0000-000000000002"
FIXED_BUILD = "0" * 64
HEADER = b"SCADMESH" + struct.pack("<II", 1, 0)


def checksum(data):
    return hashlib.sha256(data).hexdigest()


def context_digest(fields):
    encoded = (field.encode("utf-8") for field in fields)
    return checksum(b"".join(str(len(field)).encode("ascii") + b":" + field for field in encoded))


def request_for(source, logical_path, build, libraries=(), resources=()):
    path = str(logical_path)
    library_paths = [str(root) for root in libraries]
    resource_paths = [str(root) for root in resources]
    resolution = ["resolution-v1", path, "", str(len(library_paths)), *library_paths,
                  str(len(resource_paths)), *resource_paths]
    return {
        "protocolVersion": PROTOCOL,
        "requestID": FIXED_REQUEST,
        "key": {
            "documentID": FIXED_DOCUMENT,
            "sourceRevision": 1,
            "dependencyGeneration": 0,
            "resolutionDigest": context_digest(resolution),
            "optionsDigest": context_digest(["options-v1", "manifold", "false"]),
            "workerBuild": build,
        },
        "logicalPath": path,
        "snapshot": "main.scad",
        "sourceSHA256": checksum(source),
        "libraryRoots": library_paths,
        "resourceRoots": resource_paths,
        "preview": False,
        "backend": "manifold",
        "expectedWorkerBuild": build,
    }


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")


def run_job(worker, job, source, request, environment, expected_code=0):
    job.mkdir(parents=True)
    (job / "main.scad").write_bytes(source)
    write_json(job / "request.json", request)
    with (job / "stdout.log").open("wb") as stdout, (job / "stderr.log").open("wb") as stderr:
        with subprocess.Popen([str(worker), "--scadretto-job", str(job / "request.json")],
                              stdin=subprocess.PIPE, stdout=stdout, stderr=stderr,
                              cwd=job, env={**environment, "TMPDIR": str(job)}) as process:
            try:
                code = process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise
    check(code == expected_code, f"{job.name}: worker exited {code}, expected {expected_code}")
    result = json.loads((job / "result.json").read_bytes())
    check(result["protocolVersion"] == PROTOCOL and result["requestID"] == request["requestID"]
          and result["key"] == request["key"], f"{job.name}: request identity did not round-trip")
    check(result["buildSHA"] == checksum(worker.read_bytes()), f"{job.name}: executable digest differs")
    if result["detail"] not in {"protocolMismatch", "buildMismatch"}:
        main = next(file for file in result["files"] if file["kind"] == "main")
        check(main["logicalPath"] == request["logicalPath"] and main["byteLength"] == len(source)
              and main["sha256"] == checksum(source), f"{job.name}: main snapshot identity differs")
    return result


def mesh_geometry(root, descriptor):
    if descriptor is None:
        return None
    path = descriptor["path"]
    check(path in {"mesh.bin", "operands.bin"}, "invalid binary payload path")
    payload = (root / path).read_bytes()
    check(payload[:16] == HEADER, "invalid binary payload header")
    check(descriptor["positionType"] == "float64" and descriptor["indexType"] == "uint32"
          and descriptor["vertexStride"] == 24 and descriptor["indexStride"] == 4
          and descriptor["winding"] == "ccw", "invalid binary descriptor")
    vertices = list(struct.unpack_from("<ddd", payload, descriptor["vertexOffset"] + 24 * index)
                    for index in range(descriptor["vertexCount"]))
    check(descriptor["indexCount"] % 3 == 0, "partial triangle")
    triangles = list(struct.unpack_from("<III", payload, descriptor["indexOffset"] + 12 * index)
                     for index in range(descriptor["indexCount"] // 3))
    check(all(math.isfinite(axis) for vertex in vertices for axis in vertex), "nonfinite mesh position")
    check(all(index < len(vertices) for face in triangles for index in face), "invalid index")
    bounds = [[operation(vertex[axis] for vertex in vertices) for axis in range(3)]
              for operation in (min, max)]
    check(bounds == [descriptor["bounds"]["min"], descriptor["bounds"]["max"]], "mesh bounds differ")
    return {"vertices": vertices, "triangles": triangles}


def mesh_signature(root, descriptor):
    mesh = mesh_geometry(root, descriptor)
    if mesh is None:
        return None
    vertices = [tuple(round(axis, 9) for axis in vertex) for vertex in mesh["vertices"]]
    faces = [tuple(vertices[index] for index in face) for face in mesh["triangles"]]
    # Rotate equivalent triangle representations without changing winding.
    faces = [min(face, face[1:] + face[:1], face[2:] + face[:2]) for face in faces]
    return sorted(faces)


def canonical(root, result):
    instances = {item["id"]: index for index, item in enumerate(result["instances"])}
    files = {item["id"]: index for index, item in enumerate(sorted(
        result["files"], key=lambda file: (file["kind"], file["logicalPath"])))}
    operands = {item["id"]: mesh_signature(root, item["mesh"]) for item in result["operands"]}

    def span(value):
        return None if value is None else (files[value["fileID"]], value["start"], value["end"])

    rows = []
    for record in result["instances"]:
        diameter = record.get("diameter")
        rows.append((
            record["name"], instances.get(record.get("parent")), span(record.get("span")), record["iteration"],
            [round(value, 9) for value in record["local"]], [round(value, 9) for value in record["world"]],
            operands.get(record.get("operand")),
            None if diameter is None else (diameter["value"], [
                (link["kind"], link["name"], span(link.get("span"))) for link in diameter["chain"]]),
        ))
    operations = sorted((instances[operation["instanceID"]], [
        (instances[child["instanceID"]], child["role"]) for child in operation["children"]
    ]) for operation in result["operations"])
    edges = sorted((span(edge["span"]), instances[edge["instanceID"]], edge["property"])
                   for edge in result["dependencyEdges"])
    diagnostics = sorted((item["severity"], item["message"], repr(span(item.get("span"))),
                          item.get("repeatCount", 0)) for item in result["diagnostics"])
    console = [(item["group"], item["text"], span(item.get("span"))) for item in result["console"]]
    file_data = sorted((item["kind"], item["logicalPath"], item["sha256"], item["byteLength"], item["writable"])
                       for item in result["files"])
    return (result["status"], result["detail"], file_data, rows, operations, edges, diagnostics, console,
            result["droppedConsoleMessages"], mesh_signature(root, result.get("mesh")))


def check_goldens(args, environment, build):
    # A stable logical directory inside the job root supplies diagnostics without
    # hard-coding user paths into the checked examples.
    logical_base = args.evidence / "Golden source"
    logical_base.mkdir()
    cases = {
        "cube": ((args.goldens / "cube/main.scad").read_bytes(), 0, "rendered"),
        "invalid": ((args.goldens / "invalid/main.scad").read_bytes(), 1, "modelError"),
        "plate": ((args.fixtures / "mounting-plate.scad").read_bytes(), 0, "rendered"),
    }
    for name, (source, exit_code, detail) in cases.items():
        job = args.evidence / ("v1-" + name)
        logical = logical_base / (name + ".scad")
        request = request_for(source, logical, build)
        result = run_job(args.worker, job, source, request, environment, expected_code=exit_code)
        check(result["detail"] == detail, f"{name}: expected {detail}, got {result['detail']}")

        portable_path = Path("/ScadrettoGolden") / logical.name
        portable_request = request_for(source, portable_path, FIXED_BUILD)
        portable = json.loads(json.dumps(result).replace(str(logical), str(portable_path)))
        portable["key"] = portable_request["key"]
        portable["buildSHA"] = FIXED_BUILD
        golden = args.goldens / name
        if args.record:
            golden.mkdir(exist_ok=True)
            write_json(golden / "request.json", portable_request)
            write_json(golden / "result.json", portable)
            if detail == "rendered":
                shutil.copyfile(job / "mesh.bin", golden / "mesh.bin")
                shutil.copyfile(job / "operands.bin", golden / "operands.bin")
        check(json.loads((golden / "request.json").read_bytes()) == portable_request,
              f"{name}: golden request differs")
        check(canonical(job, portable) == canonical(golden, json.loads((golden / "result.json").read_bytes())),
              f"{name}: golden manifest or resolved mesh differs")

        if name == "plate":
            cutters = [record for record in result["instances"] if record["name"] == "cylinder"]
            check([record["iteration"].get("i") for record in cutters] == [0, 1, 2, 3], "wrong bore iterations")
            check(len({record["operand"] for record in cutters}) == 1, "cutter meshes were not shared")
            chain = cutters[2]["diameter"]["chain"]
            leaf = chain[-1]["span"]
            check((leaf["start"], leaf["end"]) == (74, 75) and source[leaf["start"]:leaf["end"]] == b"4",
                  "third bore did not reach the source literal")
            logical.write_bytes(source)
            ref = render_reference(args.reference, logical, job / "reference.stl", environment)
            difference = symmetric_difference(args.oracle, job, mesh_geometry(job, result["mesh"]), ref)
            check(difference < 0.001, f"v1 plate differs from reference by {difference}")
            print(f"v1 plate symmetric difference {difference:.9g}, third bore iteration 2 to bytes [74,75)")


def check_live_inputs(args, environment, build):
    files = args.evidence / "authored paths with spaces"
    paths = {name: files / name for name in ("source", "preferred", "fallback")}
    for path in paths.values():
        path.mkdir(parents=True)
    logical = paths["source"] / "live.scad"
    include = b"include <part.scad>\n"
    preferred = paths["preferred"] / "part.scad"
    fallback = paths["fallback"] / "part.scad"
    roots = [paths["preferred"], paths["fallback"]]
    fallback.write_text("cube(2);\n", encoding="utf-8")
    for name in ("fallback", "preferred", "symlink", "recovered", "missing"):
        if name == "preferred":
            preferred.write_text("sphere(r=1, $fn=16);\n", encoding="utf-8")
        elif name == "symlink":
            preferred.unlink()
            preferred.symlink_to(fallback)
        elif name == "recovered":
            preferred.unlink()
        elif name == "missing":
            fallback.unlink()
        request = request_for(include, logical, build, libraries=roots)
        result = run_job(args.worker, args.evidence / name, include, request, environment,
                         expected_code=1 if name == "missing" else 0)
        lookup = next(line for line in result["lookups"] if line["name"] == "part.scad")
        check(str(preferred) in lookup["candidates"], "missing preferred-root candidate")
        if name == "missing":
            check(lookup.get("winner") is None and result["detail"] == "modelError", "missing include not observed")
        else:
            winner = preferred if name in {"preferred", "symlink"} else fallback
            check(lookup.get("winner") == str(winner), f"{name}: unexpected include winner")
            check(lookup.get("resolvedWinner") == str(winner.resolve()), f"{name}: wrong resolved include path")
            check(any(record["kind"] == "include" and record["sha256"] == checksum(winner.read_bytes())
                      for record in result["files"]), f"{name}: include digest did not match its file bytes")

    warning = (args.fixtures / "warning-only.scad").read_bytes()
    result = run_job(args.worker, args.evidence / "warning", warning,
                     request_for(warning, logical, build), environment)
    check(result["detail"] == "rendered" and any(entry["severity"] == "warning" and entry.get("fileID") == 0
          for entry in result["diagnostics"]), "warning-only result lost the diagnostic or its geometry")
    check(any(entry["group"] == "ECHO" and "false" in entry["text"] for entry in result["console"]),
          "console did not retain final-mode echo")
    cylinder = next(instance for instance in result["instances"] if instance["name"] == "cylinder")
    leaf = cylinder["diameter"]["chain"][-1]["span"]
    check(result["files"][0]["writable"] and warning[leaf["start"]:leaf["end"]] == b"4",
          "warning-only result lost the writable diameter binding")
    for name, content, detail, code in [
        ("empty", b"difference(){ cube(2); cube(2); }\n", "empty", 0),
        ("planar", b"square(2);\n", "unsupportedDimension", 1),
    ]:
        result = run_job(args.worker, args.evidence / name, content,
                         request_for(content, logical, build), environment, expected_code=code)
        check(result["detail"] == detail and result["mesh"] is None, f"{name}: incorrect finite-state transition")

    bom = b"\xef\xbb\xbf" + warning
    result = run_job(args.worker, args.evidence / "bom", bom, request_for(bom, logical, build), environment)
    span = next(item["span"] for item in result["diagnostics"] if item["severity"] == "warning")
    check(bom[span["start"]:span["end"]] == b"missing_parameter", "BOM changed raw diagnostic offsets")

    incompatible = request_for(b"cube(2);", logical, build)
    incompatible["protocolVersion"] = 99
    result = run_job(args.worker, args.evidence / "version-mismatch", b"cube(2);", incompatible,
                     environment, expected_code=1)
    check(result["detail"] == "protocolMismatch", "worker evaluated unsupported protocol version")

    mismatched = request_for(b"cube(2);", logical, FIXED_BUILD)
    result = run_job(args.worker, args.evidence / "build-mismatch", b"cube(2);", mismatched,
                     environment, expected_code=1)
    check(result["detail"] == "buildMismatch", "worker accepted a different executable digest")

    assets = paths["source"] / "nested shafts"
    assets.mkdir()
    block_source = assets / "block.scad"
    block_source.write_text("cube([2, 3, 4]);\n", encoding="utf-8")
    block = assets / "block.stl"
    reference = render_reference(args.reference, block_source, block, environment)
    library = assets / "library.scad"
    library.write_text('module part() { import("block.stl"); }\n', encoding="utf-8")
    source = b"use <nested shafts/library.scad>\npart();\n"
    job = args.evidence / "nested-asset"
    result = run_job(args.worker, job, source, request_for(source, logical, build), environment)
    for path, kind in [(library, "use"), (block, "import")]:
        check(any(record["kind"] == kind and record["resolvedPath"] == str(path)
                  and record["sha256"] == checksum(path.read_bytes()) for record in result["files"]),
              f"missing consumed {kind} file {path.name}")
    check(symmetric_difference(args.oracle, job, mesh_geometry(job, result["mesh"]), reference) < 1e-8,
          "nested import differs from reference geometry")

    heights = paths["source"] / "terrain.dat"
    heights.write_text("1 2 1\n2 3 2\n1 2 1\n", encoding="utf-8")
    source = b'surface(file="terrain.dat");\n'
    result = run_job(args.worker, args.evidence / "heightmap", source,
                     request_for(source, logical, build), environment)
    check(result["detail"] == "rendered" and any(record["kind"] == "surface"
          and record["sha256"] == checksum(heights.read_bytes()) for record in result["files"]),
          "heightmap was not observed as a consumed file")

    source = b'linear_extrude(height=1) text("A", font="Liberation Sans");\n'
    result = run_job(args.worker, args.evidence / "font", source,
                     request_for(source, logical, build, resources=[args.resources]), environment)
    check(result["detail"] == "rendered" and any(record["kind"] == "font"
          and record["sha256"] == checksum(Path(record["resolvedPath"]).read_bytes()) for record in result["files"]),
          "bundled font was not observed as a consumed file")


def check_lifetime_pipe(args, environment, build):
    job = args.evidence / "parent-disconnect"
    job.mkdir()
    source = b"""$fn = 64;
difference() {
    cube([6010,40,6]);
    for (i = [0:599])
        translate([10 * i + 5,20,-1]) cylinder(d = 4, h = 8);
}
"""
    (job / "main.scad").write_bytes(source)
    write_json(job / "request.json", request_for(source, job / "logical.scad", build))
    with subprocess.Popen([str(args.worker), "--scadretto-job", str(job / "request.json")],
                          stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          cwd=job, env={**environment, "TMPDIR": str(job)}) as process:
        try:
            time.sleep(0.1)
            check(process.poll() is None, "disconnect fixture finished before the lifetime-pipe check")
            start = time.monotonic()
            process.stdin.close()
            process.wait(timeout=2)
            elapsed = time.monotonic() - start
            check(process.returncode != 0 and not (job / "result.json").exists(),
                  "worker published a result after its lifetime pipe closed")
            print(f"Active worker reaped {elapsed * 1000:.3f} ms after closing the lifetime pipe")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


def main():
    parser = argparse.ArgumentParser()
    for field in ("worker", "reference", "oracle", "resources", "fixtures", "goldens", "evidence"):
        parser.add_argument("--" + field, type=lambda value: Path(value).resolve(), required=True)
    parser.add_argument("--record", action="store_true")
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    home = args.evidence / "home"
    home.mkdir()
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(home),
        "LC_NUMERIC": "C",
        "LANG": "en_US.UTF-8",
        "FONTCONFIG_FILE": str(args.resources / "fonts" / "fonts.conf"),
        "XDG_CACHE_HOME": str(home),
    }
    build = checksum(args.worker.read_bytes())
    check_goldens(args, environment, build)
    check_live_inputs(args, environment, build)
    check_lifetime_pipe(args, environment, build)
    print("v1 worker protocol goldens, provenance, warnings, empty scene and dependency recovery passed")


if __name__ == "__main__":
    main()
