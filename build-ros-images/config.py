from dataclasses import dataclass, field
from collections.abc import Callable


# Registry Configurations
@dataclass(frozen=True)
class RegistryConfig:
    address: str
    username: str
    password_env: str   # Environment variable name
    secret_name: str    # Dagger secret identifier


REGISTRIES: list[RegistryConfig] = [
    RegistryConfig("docker.io", "sshawn", "DOCKERHUB_PASSWORD", "dh-secret"),
    RegistryConfig("registry.cn-beijing.aliyuncs.com", "sshawn", "ALIYUN_PASSWORD", "ali-secret"),
]


# Package Lists (Pure Data)
BASE_BUILD_PKGS: list[str] = [
    "build-essential", "cmake", "make", "gcc", "g++", "gdb",
]

BASE_DEV_PKGS: list[str] = [
    "libyaml-cpp-dev",
    "libeigen3-dev",
    "libgeographic-dev",
    "libzmq3-dev",
    "libsdl2-dev",
    "libboost-all-dev",
    "libprotobuf-dev",
]


def base_ros_pkgs(distro: str) -> list[str]:
    return [
        "python-catkin-tools",
        "python3-catkin-tools",
        "ros-dev-tools",
        f"ros-{distro}-ackermann-msgs",
        f"ros-{distro}-grid-map-msgs",
    ]


DESKTOP_TOOL_PKGS: list[str] = [
    "bash-completion",
    "rsync",
    "wget",
    "curl",
    "git",
    "git-lfs",
    "htop",
    "tmux",
    "vim",
    "python3-pip",
    "openssh-server",
]


def desktop_ros_pkgs(distro: str) -> list[str]:
    return [
        f"ros-{distro}-desktop-full",
        f"ros-{distro}-plotjuggler-ros",
    ]


BOX_PKGS: list[str] = [
    # System Services
    "systemd", "systemd-sysv", "libpam-systemd",
    "dbus", "dbus-user-session",
    # Basic Tools
    "sudo", "ca-certificates", "less", "nano", "vim", "curl", "wget",
    "git", "git-lfs", "openssh-client",
    # Localization
    "locales", "tzdata", "bash-completion", "language-pack-en",
    # Desktop Basics
    "xdg-utils", "xdg-user-dirs", "shared-mime-info", "desktop-file-utils",
    # Fonts
    "fontconfig", "fonts-noto-core", "fonts-noto-cjk", "fonts-noto-color-emoji",
    # Icon Themes
    "adwaita-icon-theme", "hicolor-icon-theme",
    # OpenGL / Mesa
    "libgl1-mesa-dri", "libglx-mesa0", "libegl1", "libgbm1", "libdrm2", "mesa-utils",
    # Vulkan
    "libvulkan1", "mesa-vulkan-drivers", "vulkan-tools",
    # Audio
    "libpulse0", "pulseaudio-utils",
    "pipewire-alsa", "pipewire-jack", "pipewire-audio-client-libraries", "alsa-utils",
    # X11 Dependencies
    "libxkbcommon0", "libxrandr2", "libxss1", "libxtst6", "libnss3", "libcups2", "libasound2",
    "libx11-6", "libxext6", "libxi6", "libxrender1", "libxcursor1",
    "libxcomposite1", "libxdamage1", "libxfixes3",
    # Wayland
    "libwayland-client0", "libwayland-cursor0", "libwayland-egl1",
    # GTK
    "libgtk-3-0",
    # Clipboard
    "wl-clipboard", "xclip", "xauth",
    # Compression
    "unzip",
    # Shell
    "zsh",
    # Network
    "iproute2", "iputils-ping", "traceroute", "mtr", "tcpdump",
    "bind9-host",
    # Documentation
    "man-db", "manpages",
    # System Tools
    "lsof", "time", "tree", "zip", "pigz", "bc", "dialog",
    "apt-utils",
    # mDNS
    "avahi-daemon", "libnss-mdns", "libnss-myhostname",
    # Compatibility Libraries
    "libegl1-mesa", "libgl1-mesa-glx",
    "libgtk2.0-0", "libgtk2.0-bin",
    "librsvg2-common", "libvte-2.91-common",
]


# Step Descriptors
@dataclass(frozen=True)
class AptStep:
    static_pkgs: list[str] = field(default_factory=list)
    distro_pkgs_fn: Callable[[str], list[str]] | None = None


@dataclass(frozen=True)
class ScriptStep:
    host_path: str


Step = AptStep | ScriptStep


# Image Specifications
@dataclass(frozen=True)
class ImageSpec:
    tier: str                       # "base", "desktop", "box"
    image_name_template: str        # "{distro}", "{distro}-desktop"
    base_image_template: str        # "ros", "sshawn/{distro}"
    base_tag_template: str          # "{distro}", "" (empty = use arch)
    steps: tuple[Step, ...]
    depends_on: str = ""            # Dependent tier name


IMAGE_SPECS: list[ImageSpec] = [
    ImageSpec(
        tier="base",
        image_name_template="{distro}",
        base_image_template="ros",
        base_tag_template="{distro}",
        steps=(
            AptStep(
                static_pkgs=BASE_BUILD_PKGS + BASE_DEV_PKGS,
                distro_pkgs_fn=base_ros_pkgs,
            ),
            ScriptStep(host_path="inject-scripts/install_protobuf.sh"),
        ),
    ),
    ImageSpec(
        tier="desktop",
        image_name_template="{distro}-desktop",
        base_image_template="sshawn/{distro}",
        base_tag_template="",
        steps=(
            AptStep(
                static_pkgs=DESKTOP_TOOL_PKGS,
                distro_pkgs_fn=desktop_ros_pkgs,
            ),
        ),
        depends_on="base",
    ),
    ImageSpec(
        tier="box",
        image_name_template="{distro}-box",
        base_image_template="sshawn/{distro}-desktop",
        base_tag_template="",
        steps=(
            AptStep(static_pkgs=BOX_PKGS),
        ),
        depends_on="desktop",
    ),
]
