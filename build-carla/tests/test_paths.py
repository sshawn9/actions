"""Run with: python3 -m unittest discover -s build-carla/tests -v"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


BUILD_SCRIPTS = Path(__file__).resolve().parents[1]
PATH_SETTINGS = (
    "CARLA_WORK_ROOT", "CARLA_SOURCE_DIR", "CARLA_OUTPUT_DIR", "CARLA_STATE_DIR",
    "CARLA_PYTHON_ROOT", "CARLA_PYTHON_PACKAGE_ROOT", "CARLA_PYTHON_SHIM_DIR",
    "CARLA_AUDITWHEEL_VENV", "UV_PYTHON_INSTALL_DIR", "UV_CACHE_DIR",
)


class PathTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="carla-path-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / "repository"
        self.scripts = self.repo / "build-carla"
        (self.scripts / "lib").mkdir(parents=True)
        for filename in ("clean.sh", "lib/common.sh"):
            shutil.copy2(BUILD_SCRIPTS / filename, self.scripts / filename)
        self.work = self.scripts / ".work"
        self.output = self.scripts / "dist/wheels"
        self.work.mkdir()
        self.output.mkdir(parents=True)
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("CARLA_", "UV_", "BASH_FUNC_"))
            and key not in ("BASH_ENV", "ENV", "CDPATH")
        }
        # Never let a regression execute rm, even for a rejected root path.
        mock_bin = self.root / "bin"
        mock_bin.mkdir()
        mock_rm = mock_bin / "rm"
        mock_rm.write_text(
            '#!/usr/bin/env bash\n'
            'printf "%s\\0" "$@" >> "$CARLA_TEST_RM_LOG"\n'
        )
        mock_rm.chmod(0o755)
        self.rm_log = self.root / "rm.log"
        self.env.update(
            PATH=f"{mock_bin}:{self.env['PATH']}",
            CARLA_TEST_RM_LOG=str(self.rm_log),
        )

    def clean(self, option="--work", **settings):
        self.rm_log.unlink(missing_ok=True)
        return subprocess.run(
            ["bash", str(self.scripts / "clean.sh"), option],
            cwd=self.repo, env={**self.env, **settings},
            capture_output=True, text=True, timeout=10,
        )

    def rm_arguments(self):
        if not self.rm_log.exists():
            return []
        return self.rm_log.read_bytes().decode().rstrip("\0").split("\0")

    def test_rejects_repository_scripts_and_ancestors(self):
        alias = self.root / "repository-link"
        alias.symlink_to(self.repo, target_is_directory=True)
        targets = (
            "/", ".", "..", str(self.repo), f"{self.repo}/",
            f"{self.repo}/.", f"{self.scripts}/..", str(self.scripts),
            str(self.root), str(alias), f"{alias}/", f"{alias}/build-carla/..",
            f"{self.repo}/missing/..",
        )
        for option, setting in (("--work", "CARLA_WORK_ROOT"),
                                ("--output", "CARLA_OUTPUT_DIR")):
            for target in targets:
                with self.subTest(option=option, target=target):
                    result = self.clean(option, **{setting: target})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("refusing unsafe cleanup target", result.stderr)
                    self.assertEqual(self.rm_arguments(), [])

    def test_all_validates_every_target_before_removal(self):
        result = self.clean("--all", CARLA_OUTPUT_DIR=f"{self.repo}/")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.rm_arguments(), [])

    def test_default_cleanup_targets(self):
        for option, targets in (("--work", (self.work,)),
                                ("--output", (self.output,)),
                                ("--all", (self.work, self.output))):
            with self.subTest(option=option):
                result = self.clean(option)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    self.rm_arguments(),
                    [arg for target in targets for arg in ("-rf", "--", str(target))],
                )

    def test_relative_cleanup_target(self):
        for suffix in ("", "/", "//"):
            with self.subTest(suffix=suffix):
                result = self.clean(CARLA_WORK_ROOT=f"build-carla/.work{suffix}")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.rm_arguments(), ["-rf", "--", str(self.work)])

    def test_cleanup_preserves_symlink_targets(self):
        external = self.root / "external-work"
        external.mkdir()
        for name, destination in (("work-link", external),
                                  ("dangling-link", self.root / "missing")):
            with self.subTest(name=name):
                link = self.repo / name
                link.symlink_to(destination, target_is_directory=True)
                for suffix in ("", "/", "//"):
                    with self.subTest(suffix=suffix):
                        result = self.clean(CARLA_WORK_ROOT=f"{link}{suffix}")
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(self.rm_arguments(), ["-rf", "--", str(link)])

    def test_python_paths_survive_directory_changes(self):
        for overrides in (
            {"CARLA_WORK_ROOT": "relative-work"},
            {name: f"relative-{name.lower()}" for name in PATH_SETTINGS},
        ):
            with self.subTest(overrides=overrides):
                result = subprocess.run(
                    ["bash", "-euc", '''
source "$1/lib/common.sh"
for name in "${@:2}"; do
  [[ "${!name}" == "$PWD/"* ]]
done
mkdir -p "$CARLA_SOURCE_DIR/Build" "$CARLA_PYTHON_SHIM_DIR" \
  "$CARLA_PYTHON_PACKAGE_ROOT/python-3.14"
touch "$CARLA_PYTHON_PACKAGE_ROOT/python-3.14/build-dependency"
cat > "$CARLA_PYTHON_SHIM_DIR/python3.14" <<'SHIM'
#!/usr/bin/env bash
set -eu
test -f "$PYTHONPATH/build-dependency"
SHIM
chmod +x "$CARLA_PYTHON_SHIM_DIR/python3.14"
export PATH="$CARLA_PYTHON_SHIM_DIR:$PATH"
export PYTHONPATH="$CARLA_PYTHON_PACKAGE_ROOT/python-3.14"
expected_shim="$(command -v python3.14)"
cd "$CARLA_SOURCE_DIR/Build"
source "$1/lib/common.sh"
[[ "$(command -v python3.14)" == "$expected_shim" ]]
python3.14
''', "path-test", str(self.scripts), *PATH_SETTINGS],
                    cwd=self.repo, env={**self.env, **overrides},
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
