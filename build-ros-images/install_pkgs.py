from base import *


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

def install_base_for(ros_distro: str, platform: dagger.Platform):
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

    ros_pkgs = f"""
    python-catkin-tools 
    python3-catkin-tools 
    ros-dev-tools
    ros-{ros_distro}-ackermann-msgs
    ros-{ros_distro}-grid-map-msgs
    """.split()

    all_pkgs = base_build_pkgs + development_pkgs + ros_pkgs

    arch = arch_of(platform)

    def _fn(container: dagger.Container) -> dagger.Container:
        return apt_install(
            container,
            all_pkgs,
            apt_cache_name=f"apt-archives-{ros_distro}-{arch}",
        )

    return _fn

def install_desktop_for(ros_distro: str, platform: dagger.Platform):
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
    ros-{ros_distro}-desktop-full
    ros-{ros_distro}-plotjuggler-ros
    """.split()

    all_pkgs = tool_pkgs + ros_pkgs

    arch = arch_of(platform)

    def _fn(container: dagger.Container) -> dagger.Container:
        return apt_install(
            container,
            all_pkgs,
            apt_cache_name=f"apt-archives-{ros_distro}-{arch}",
        )

    return _fn

def install_box_for(ros_distro: str, platform: dagger.Platform):
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

    all_pkgs = box_pkgs

    arch = arch_of(platform)

    def _fn(container: dagger.Container) -> dagger.Container:
        return apt_install(
            container,
            all_pkgs,
            apt_cache_name=f"apt-archives-{ros_distro}-{arch}",
        )

    return _fn
