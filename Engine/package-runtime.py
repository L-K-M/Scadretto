"""Stage a redistributable runtime closure from the pinned dependency prefix."""

import re
import shutil
import subprocess
import sys
from pathlib import Path


def tool(*args):
    return subprocess.run(args, text=True, check=True, stdout=subprocess.PIPE).stdout


def install_names(binary):
    return [
        name
        for line in tool("otool", "-L", binary).splitlines()[1:]
        if (name := line.strip().partition(" (compatibility")[0])
    ]


def rpaths(binary):
    commands = tool("otool", "-l", binary)
    return re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", commands)


def validate(binary, target):
    if tool("lipo", "-archs", binary).strip() != "arm64":
        raise ValueError(f"Expected arm64-only binary: {binary}")
    build = tool("vtool", "-show-build", binary)
    versions = re.findall(r"^\s*(?:minos|version)\s+(\d+(?:\.\d+)+)$", build, re.MULTILINE)
    if len(versions) != 1:
        raise ValueError(f"Missing or ambiguous deployment target: {binary}")
    version = lambda value: tuple(int(part) for part in (value + ".0.0").split(".")[:3])
    if version(versions[0]) > version(target):
        raise ValueError(f"{binary} requires macOS {versions[0]}, expected {target} or earlier")


def package(executable, prefix, frameworks, target):
    bundled = {}
    commands = {}

    def visit(source, destination, is_executable=False):
        validate(source, target)
        names = install_names(source)
        changes = []
        if not is_executable:
            # The first entry for a dylib is its own LC_ID_DYLIB.
            changes.extend(("-id", f"@rpath/{destination.name}"))
            names = names[1:]
        for name in names:
            if name.startswith(("/usr/lib/", "/System/Library/")):
                continue
            input_path = Path(name)
            if not input_path.is_absolute():
                input_path = prefix / "lib" / input_path.name
            input_path = input_path.resolve(strict=True)
            if not input_path.is_relative_to(prefix):
                raise ValueError(f"Dependency outside pinned prefix: {name}")
            previous = bundled.get(input_path.name)
            if previous is None:
                bundled[input_path.name] = input_path
                output = frameworks / input_path.name
                shutil.copy2(input_path, output)
                visit(input_path, output)
            elif previous != input_path:
                raise ValueError(f"Conflicting libraries named {input_path.name}")
            changes.extend(("-change", name, f"@rpath/{input_path.name}"))

        # All non-system load commands use the executable's Frameworks directory.
        for rpath in dict.fromkeys(rpaths(source)):
            changes.extend(("-delete_rpath", rpath))
        if is_executable:
            changes.extend(("-add_rpath", "@executable_path/../Frameworks"))
        commands[destination] = changes

    visit(executable, executable, is_executable=True)
    for binary, changes in commands.items():
        tool("install_name_tool", *changes, binary)
        tool("codesign", "--force", "--sign", "-", binary)
        tool("codesign", "--verify", "--strict", binary)
        for name in install_names(binary):
            if name.startswith(("/usr/lib/", "/System/Library/")):
                continue
            if not name.startswith("@rpath/") or not (frameworks / name[7:]).is_file():
                raise ValueError(f"Unexpected link after staging {binary}: {name}")


if __name__ == "__main__":
    executable, prefix, frameworks = [Path(path).resolve() for path in sys.argv[1:4]]
    package(executable, prefix, frameworks, sys.argv[4])
