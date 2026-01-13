import os
import sys
import shlex
import textwrap
import asyncio
from datetime import datetime
from zoneinfo import ZoneInfo
import dagger
from dagger import dag


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

        for p in "${pkgs[@]}"; do
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

def install_pkgs_for(ros_distro: str, arch: str):
    base_build_pkgs = """
    build-essential cmake make gcc g++ gdb
    """.split()

    development_pkgs = """
    libyaml-cpp-dev
    libeigen3-dev
    libgeographic-dev
    libzmq3-dev
    libsdl2-dev
    libboost-all-dev
    libprotobuf-dev
    """.split()

    tool_pkgs = """
    bash-completion
    rsync
    wget
    curl
    git
    git-lfs
    htop
    tmux
    vim
    python3-pip
    openssh-server
    """.split()

    ros_pkgs = f"""
    python-catkin-tools 
    python3-catkin-tools 
    ros-dev-tools
    ros-{ros_distro}-desktop-full
    ros-{ros_distro}-plotjuggler-ros
    ros-{ros_distro}-ackermann-msgs
    ros-{ros_distro}-grid-map-msgs
    """.split()

    box_pkgs = """
    systemd systemd-sysv libpam-systemd
    dbus dbus-user-session
    sudo ca-certificates less nano vim curl wget git git-lfs openssh-client
    locales tzdata bash-completion
    xdg-utils xdg-user-dirs shared-mime-info desktop-file-utils
    fontconfig fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
    adwaita-icon-theme hicolor-icon-theme
    libgl1-mesa-dri libglx-mesa0 libegl1 libgbm1 libdrm2 mesa-utils
    libvulkan1 mesa-vulkan-drivers vulkan-tools
    libpulse0 pulseaudio-utils pipewire-alsa pipewire-jack pipewire-audio-client-libraries alsa-utils
    libxkbcommon0 libxrandr2 libxss1 libxtst6 libnss3 libcups2 libasound2
    libx11-6 libxext6 libxi6 libxrender1 libxcursor1 libxcomposite1 libxdamage1 libxfixes3
    libwayland-client0 libwayland-cursor0 libwayland-egl1
    libgtk-3-0
    wl-clipboard xclip xauth
    unzip
    """.split()

    all_pkgs = base_build_pkgs + development_pkgs + tool_pkgs + ros_pkgs + box_pkgs

    def _fn(container: dagger.Container) -> dagger.Container:
        return apt_install(
            container,
            all_pkgs,
            apt_cache_name=f"apt-archives-{ros_distro}-{arch}",
        )

    return _fn

async def publish_with_retry(
    ctr: dagger.Container,
    ref: str,
    *,
    platform_variants: list[dagger.Container] | None,
    sem: asyncio.Semaphore,
    retries: int = 3,
) -> None:
    async with sem:
        delay = 1.0
        for i in range(retries):
            try:
                await ctr.publish(ref, platform_variants=platform_variants or None)
                return
            except Exception:
                if i == retries - 1:
                    raise
                await asyncio.sleep(delay)
                delay *= 2.0


async def build_dev_container():
    docker_addr = "docker.io"
    ali_addr = "registry.cn-beijing.aliyuncs.com"
    username = "sshawn"

    dh_pass = dag.set_secret("dh-secret", os.environ.get("DOCKERHUB_PASSWORD", ""))
    ali_pass = dag.set_secret("ali-secret", os.environ.get("ALIYUN_PASSWORD", ""))

    ros_distros = ["noetic", "humble", "jazzy"]
    platforms = [dagger.Platform("linux/amd64"), dagger.Platform("linux/arm64")]
    tp = os.environ.get("TARGET_PLATFORMS", "").strip()
    if tp:
        platforms = [dagger.Platform(x.strip()) for x in tp.split(",") if x.strip()]

    build_date = datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y%m%d")
    build_date = os.environ.get("BUILD_DATE") or build_date
    created = datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(timespec="seconds")

    publish_conc = int(os.environ.get("PUBLISH_CONCURRENCY", "6"))
    sem = asyncio.Semaphore(publish_conc)

    manifest_only = os.environ.get("MANIFEST_ONLY") == "1"

    cfg = dagger.Config(log_output=sys.stderr)
    async with dagger.connection(cfg):
        async with asyncio.TaskGroup() as tg:
            for distro in ros_distros:
                base_image = f"ros:{distro}"
                image_name = f"{distro}-box"
                dh_repo = f"{docker_addr}/{username}/{image_name}"
                ali_repo = f"{ali_addr}/{username}/{image_name}"

                if manifest_only:
                    def variants_for(repo: str) -> list[dagger.Container]:
                        vs = []
                        for platform in platforms:
                            arch = str(platform).split("/")[-1]
                            vs.append(
                                dag.container(platform=platform)
                                .with_registry_auth(docker_addr, username, dh_pass)
                                .with_registry_auth(ali_addr, username, ali_pass)
                                .from_(f"{repo}:{arch}")
                            )
                        return vs

                    for repo in (dh_repo, ali_repo):
                        vs = variants_for(repo)
                        main = vs[0]
                        others = vs[1:] or None
                        for tag in (build_date, "latest"):
                            tg.create_task(publish_with_retry(
                                main, f"{repo}:{tag}",
                                platform_variants=others, sem=sem,
                            ))
                    continue

                variants: list[dagger.Container] = []
                for platform in platforms:
                    arch = str(platform).split("/")[-1]
                    ctr = (
                        dag.container(platform=platform)
                        .from_(base_image)
                        .with_(install_pkgs_for(distro, arch))
                        .with_label("org.opencontainers.image.created", created)
                        .with_label("org.opencontainers.image.version", build_date)
                        .with_registry_auth(docker_addr, username, dh_pass)
                        .with_registry_auth(ali_addr, username, ali_pass)
                    )
                    variants.append(ctr)

                    for repo in (dh_repo, ali_repo):
                        tg.create_task(publish_with_retry(
                            ctr, f"{repo}:{arch}",
                            platform_variants=None, sem=sem,
                        ))

                main = variants[0]
                platform_variants = variants[1:] or None
                if platform_variants is None:
                    continue

                for repo in (dh_repo, ali_repo):
                    for tag in (f"{build_date}", "latest"):
                        tg.create_task(publish_with_retry(
                            main, f"{repo}:{tag}",
                            platform_variants=platform_variants, sem=sem,
                        ))


if __name__ == "__main__":
    asyncio.run(build_dev_container())
