# CARLA 0.9.15 Python wheels

These scripts build the CARLA 0.9.15 client library and CPython wheels through
CARLA's original Make/BuildTools dependency chain. GitHub Actions and local
builds call the same scripts.

The default remains CPython 3.9 through 3.14. The final wheels target
`manylinux_2_31_x86_64`, so every native dependency must be compiled with glibc
2.31 or older. A newer glibc can run such wheels, but a wheel built against a
newer glibc cannot honestly be relabelled as 2.31.

## Reproducible local build

On any x86-64 Linux host with Docker or Podman:

```bash
./build-carla/run-in-container.sh
```

The Debian 11 container is only the ABI baseline. It does not create six
separate build environments: one container builds shared CARLA dependencies and
all six wheels. Results are written to `build-carla/dist/wheels` and
intermediates to `build-carla/.work`.

The source phase uses a blob-filtered sparse checkout containing only
`LibCarla`, `PythonAPI`, `Util`, and CARLA's root build files. The large Unreal
and documentation trees are not downloaded, which saves roughly 2 GB before
compilation on the 0.9.15 tag. A legacy full SUMO cache left by an older run is
also replaced with the pinned 58 MB sparse checkout automatically.

To build fewer versions while testing:

```bash
./build-carla/run-in-container.sh --python-versions 3.10,3.14
```

## Native Debian 11 build

```bash
sudo ./build-carla/install-dependencies-debian.sh
sudo ./build-carla/install-uv.sh
./build-carla/build.sh
```

Individual phases can be rerun directly:

```bash
./build-carla/prepare-python.sh
./build-carla/fetch-source.sh
./build-carla/build-wheels.sh
./build-carla/repair-wheels.sh
./build-carla/write-metadata.sh
```

After a failed CARLA dependency build, start from a clean work directory. Some
upstream Setup.sh dependency checks use directory existence rather than a
completion marker, so reusing a half-populated install directory is unsafe:

```bash
./build-carla/clean.sh --work
```

Use `--all` to remove both intermediates and output artifacts.

## Why a compatibility patch is still required

`patches/carla-0.9.15-hosted-runner.patch` keeps CARLA's build process but
adapts assumptions that no longer hold on a hosted runner:

- use the host Clang/libc++ when a full UE4 source tree is absent;
- use the 0.9.15.2 replacement download endpoints for moved archives;
- shallow-fetch CARLA's pinned SUMO commit with only the OSM2ODR source and
  CMake modules instead of cloning its 2.5 GB history and test tree;
- run CARLA's LibCarla, OSM2ODR, and PythonAPI BuildTools recipes sequentially
  after the explicit multi-Python setup, avoiding a second default setup pass;
- use `distro.id()` because `distro.linux_distribution()` was removed;
- apply Boost.Python's upstream `PyEval_CallMethod` to `PyObject_CallMethod`
  fix, required by CPython 3.13 and 3.14;
- apply Boost.Python's upstream enum GC-flag fix, required at import time by
  CPython 3.11 and newer;
- build patchelf 0.18.0 because auditwheel 6.7 requires patchelf 0.14 or newer;
- preserve Debian's 2 MiB x86-64 ELF segment alignment when auditwheel invokes
  patchelf, preventing corrupted bundled TIFF/JBIG dependencies;
- compile PROJ C sources as PIC before linking them into the Python extension.

Python build packages and auditwheel are pinned. Managed CPython base
interpreters are used directly for compilation so `sys.prefix` points to the
complete development headers; pure-Python packaging dependencies are exposed by
per-version wrapper scripts and do not modify uv's managed installations.
