"""Exercise a nested transitive dependency through the real macOS loader."""

from pathlib import Path
import subprocess
import sys
import tempfile


def run(*command, **options):
    subprocess.run(command, check=True, timeout=30, **options)


def verify(stager, target):
    with tempfile.TemporaryDirectory(prefix="Scadretto runtime ") as scratch:
        root = Path(scratch)
        prefix, product = root / "prefix", root / "product"
        leaf = prefix / "lib" / "nested" / "libleaf.dylib"
        middle = prefix / "lib" / "libmiddle.dylib"
        executable = product / "bin" / "sample"
        leaf.parent.mkdir(parents=True)
        executable.parent.mkdir(parents=True)

        leaf_source, middle_source, main_source = [root / name for name in
                                                   ("leaf.c", "middle.c", "main.c")]
        leaf_source.write_text("int leaf(void) { return 41; }\n")
        middle_source.write_text("int leaf(void); int middle(void) { return leaf() + 1; }\n")
        main_source.write_text("int middle(void); int main(void) { return middle() != 42; }\n")
        compiler = ("xcrun", "clang", "-arch", "arm64", f"-mmacosx-version-min={target}",
                    "-Wl,-headerpad_max_install_names")
        run(*compiler, "-dynamiclib", "-Wl,-install_name,@loader_path/nested/libleaf.dylib",
            leaf_source, "-o", leaf)
        run(*compiler, "-dynamiclib", middle_source, leaf, "-o", middle)
        run(*compiler, main_source, middle, "-o", executable)
        run(sys.executable, stager, executable, prefix, product / "Frameworks", target)

        # The original paths must be gone, and the leaf is loaded only via the
        # middle library. Executable and dylib signatures are checked by staging.
        prefix.rename(root / "source-runtime")
        relocated = root / "relocated product"
        product.rename(relocated)
        run(relocated / "bin" / "sample", env={"PATH": "/usr/bin:/bin"})


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(), sys.argv[2])
