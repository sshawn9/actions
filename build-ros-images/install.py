import shlex
import textwrap

import dagger
from dagger import dag

from config import AptStep, ScriptStep, Step


def arch_of(platform: dagger.Platform) -> str:
    return str(platform).split("/")[-1]


def apt_install(
    container: dagger.Container,
    pkgs: list[str],
    *,
    report_path: str = "/var/log/dagger/apt-install.log",
    apt_cache_name: str = "apt-archives",
) -> dagger.Container:
    seen: set[str] = set()
    pkgs = [p for p in pkgs if not (p in seen or seen.add(p))]

    apt_cache = dag.cache_volume(apt_cache_name)  # /var/cache/apt/archives
    pkg_str = " ".join(shlex.quote(p) for p in pkgs)
    report = shlex.quote(report_path)

    cmd = textwrap.dedent(f"""
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        trap 'rc=$?; tail -n 200 /var/log/apt/term.log || true; tail -n 200 /var/log/dpkg.log || true; df -h || true; exit $rc' ERR
        apt-get update -o Acquire::Retries=3

        install -d -m 0755 /var/cache/apt/archives/partial
        chmod -R u+rwX,go+rX /var/cache/apt/archives

        pkgs=({pkg_str})
        to_install=()
        skipped=()

        for p in "${{pkgs[@]}}"; do
          pol="$(apt-cache policy "$p" 2>/dev/null || true)"
          cand="$(awk -F': ' '/Candidate:/ {{print $2; exit}}' <<<"$pol" || true)"
          if [[ -n "$cand" && "$cand" != "(none)" ]]; then
            to_install+=("$p")
          else
            skipped+=("$p")
          fi
        done

        ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        mkdir -p "$(dirname {report})"
        {{
          echo "----- $ts -----"
          echo "requested: ${{pkgs[*]:-}}"
          echo "installed: ${{to_install[*]:-}}"
          echo "skipped_not_in_repo: ${{skipped[*]:-}}"
          echo
        }} >> {report}

        if (( ${{#to_install[@]}} )); then
          apt-get install -y --no-install-recommends "${{to_install[@]}}"
        fi

        rm -rf /var/lib/apt/lists/*
    """)

    return (
        container
        .with_mounted_cache("/var/cache/apt/archives", apt_cache)
        .with_exec(["bash", "-lc", cmd])
    )


def resolve_step(
    step: Step,
    distro: str,
    platform: dagger.Platform,
):
    """将 Step 数据描述符转换为 Dagger .with_() 回调"""
    match step:
        case AptStep(static_pkgs=static, distro_pkgs_fn=fn):
            pkgs = list(static)
            if fn is not None:
                pkgs += fn(distro)
            arch = arch_of(platform)

            def _apt(ctr: dagger.Container) -> dagger.Container:
                return apt_install(
                    ctr, pkgs,
                    apt_cache_name=f"apt-archives-{distro}-{arch}",
                )
            return _apt

        case ScriptStep(host_path=path):
            filename = path.split("/")[-1]

            def _script(ctr: dagger.Container) -> dagger.Container:
                script = dag.host().file(path)
                return (
                    ctr
                    .with_mounted_file(f"/tmp/{filename}", script)
                    .with_exec(["bash", "-lc", f"chmod +x /tmp/{filename} && /tmp/{filename}"])
                )
            return _script

        case _:
            raise TypeError(f"Unknown step type: {type(step)}")
