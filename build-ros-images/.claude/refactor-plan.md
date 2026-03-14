# build-ros-images 重构计划：数据驱动流水线

## Context

当前项目约 550 行 Python，用 Dagger 构建多架构 ROS Docker 镜像（base/desktop/box × noetic/humble/jazzy × amd64/arm64），推送到 DockerHub + Aliyun 两个 registry。

**核心问题：** "构建什么"（镜像规格、包列表）和"怎么构建"（Dagger 操作、推送、manifest）完全耦合在一起，导致 3 个 build 函数、3 个 install 函数几乎完全重复，加新 tier 或 registry 需要在多处复制粘贴。

**目标：** 数据与方法分离——镜像定义是纯数据，构建引擎是通用方法。新增 image tier 只需加一条 ImageSpec，新增 registry 只需加一条 RegistryConfig。

---

## 重构后文件结构

```
build-ros-images/
├── main.py              # 入口（~40行）：环境解析 + 主循环
├── config.py            # 纯数据（~90行）：RegistryConfig, ImageSpec, 包列表
├── env.py               # 配置（~50行）：BuildEnv dataclass
├── install.py           # 方法（~80行）：apt_install + resolve_step
├── builder.py           # 方法（~90行）：通用构建引擎
├── publish.py           # 方法（~38行）：不变
├── inject-scripts/
│   └── install_protobuf.sh
└── pyproject.toml
```

**删除的文件：**
- `base.py` → 拆分为 `env.py`（BuildEnv）+ `config.py`（RegistryConfig）
- `install_pkgs.py` → 包列表移入 `config.py`，apt_install 移入 `install.py`
- `install_protobuf.py` → 完全由 `ScriptStep` 数据 + `resolve_step` 替代
- `single_distro.py` → 逻辑合并入 `builder.py`

---

## 文件设计

### 1. `config.py` — 纯数据层（零 Dagger 导入）

```python
from dataclasses import dataclass, field
from collections.abc import Callable

# ═══ Registry 配置 ═══

@dataclass(frozen=True)
class RegistryConfig:
    address: str
    username: str
    password_env: str    # 环境变量名
    secret_name: str     # Dagger secret 标识符

REGISTRIES: list[RegistryConfig] = [
    RegistryConfig("docker.io", "sshawn", "DOCKERHUB_PASSWORD", "dh-secret"),
    RegistryConfig("registry.cn-beijing.aliyuncs.com", "sshawn", "ALIYUN_PASSWORD", "ali-secret"),
]

# ═══ 包列表（纯数据） ═══

BASE_BUILD_PKGS: list[str] = [
    "build-essential", "cmake", "make", "gcc", "g++", "gdb",
]

BASE_DEV_PKGS: list[str] = [
    "libyaml-cpp-dev", "libeigen3-dev", "libgeographic-dev",
    "libzmq3-dev", "libsdl2-dev", "libboost-all-dev", "libprotobuf-dev",
]

def base_ros_pkgs(distro: str) -> list[str]:
    return [
        "python-catkin-tools", "python3-catkin-tools", "ros-dev-tools",
        f"ros-{distro}-ackermann-msgs", f"ros-{distro}-grid-map-msgs",
    ]

DESKTOP_TOOL_PKGS: list[str] = [
    "bash-completion", "rsync", "wget", "curl", "git", "git-lfs",
    "htop", "tmux", "vim", "python3-pip", "openssh-server",
]

def desktop_ros_pkgs(distro: str) -> list[str]:
    return [f"ros-{distro}-desktop-full", f"ros-{distro}-plotjuggler-ros"]

BOX_PKGS: list[str] = [
    "systemd", "systemd-sysv", "libpam-systemd",
    "dbus", "dbus-user-session",
    # ... 完整列表见 config.py ...
]

# ═══ Step 描述符（纯数据） ═══

@dataclass(frozen=True)
class AptStep:
    static_pkgs: list[str] = field(default_factory=list)
    distro_pkgs_fn: Callable[[str], list[str]] | None = None

@dataclass(frozen=True)
class ScriptStep:
    host_path: str   # e.g. "inject-scripts/install_protobuf.sh"

Step = AptStep | ScriptStep

# ═══ 镜像规格（纯数据） ═══

@dataclass(frozen=True)
class ImageSpec:
    tier: str                      # "base", "desktop", "box"
    image_name_template: str       # "{distro}", "{distro}-desktop"
    base_image_template: str       # "ros", "sshawn/{distro}"
    base_tag_template: str         # "{distro}", ""（空=用arch）
    steps: tuple[Step, ...]
    depends_on: str = ""           # 依赖的 tier 名

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
        steps=(AptStep(static_pkgs=BOX_PKGS),),
        depends_on="desktop",
    ),
]
```

**设计要点：**
- `distro_pkgs_fn` 用 `Callable` 而非字符串引用，更 Pythonic，IDE 可跳转
- `RegistryConfig` 是 frozen dataclass，新增 registry 只需加一行
- `ImageSpec` 完全描述一个镜像 tier：名称模板、基础镜像、安装步骤、依赖关系
- 新增 tier（如 "sim"）= 加一个 `ImageSpec` + 对应包列表，零逻辑改动

---

### 2. `env.py` — BuildEnv（运行时配置）

```python
import asyncio
from dataclasses import dataclass, field
import dagger

from config import RegistryConfig

@dataclass
class BuildEnv:
    distros: list[str]
    platforms: list[dagger.Platform]
    registries: list[RegistryConfig]
    manifest_only: bool
    manifest_tag: str
    build_date: str
    created: str
    rebuild: dict[str, bool]       # {"base": True, "desktop": True, ...}
    sem: asyncio.Semaphore = field(default_factory=lambda: asyncio.Semaphore(1))
```

**设计要点：**
- 不再在 field default_factory 中读环境变量，所有 env 解析集中在 `main.py` 的 `create_env_from_os()`
- `rebuild` 是 dict 而非 3 个 bool 字段，主循环可以用 `env.rebuild[spec.tier]` 通用判断
- `registries` 是列表，构建引擎迭代它而非硬编码两个 registry

---

### 3. `install.py` — 步骤执行（替代 install_pkgs.py + install_protobuf.py）

```python
import shlex, textwrap
import dagger
from dagger import dag
from config import AptStep, ScriptStep, Step

def arch_of(platform: dagger.Platform) -> str:
    return str(platform).split("/")[-1]

def apt_install(container, pkgs, *, report_path="...", apt_cache_name="apt-archives"):
    # 完全复用原 install_pkgs.py 的实现
    ...

def resolve_step(step: Step, distro: str, platform: dagger.Platform):
    """将 Step 数据描述符转换为 Dagger .with_() 回调"""
    match step:
        case AptStep(static_pkgs=static, distro_pkgs_fn=fn):
            pkgs = list(static)
            if fn is not None:
                pkgs += fn(distro)
            arch = arch_of(platform)
            def _apt(ctr: dagger.Container) -> dagger.Container:
                return apt_install(ctr, pkgs, apt_cache_name=f"apt-archives-{distro}-{arch}")
            return _apt

        case ScriptStep(host_path=path):
            filename = path.split("/")[-1]
            def _script(ctr: dagger.Container) -> dagger.Container:
                script = dag.host().file(path)
                return (
                    ctr.with_mounted_file(f"/tmp/{filename}", script)
                    .with_exec(["bash", "-lc", f"chmod +x /tmp/{filename} && /tmp/{filename}"])
                )
            return _script
```

**设计要点：**
- `resolve_step` 用 Python 3.10+ 的 match/case，按 Step 类型分发
- `install_protobuf.py` 完全删除，由 `ScriptStep` + `case ScriptStep` 替代
- 3 个 `install_xxx_for` 函数完全删除，由 `AptStep` 数据 + `case AptStep` 替代
- 新增步骤类型（如 PipStep）= 加一个 dataclass + 一个 case 分支

---

### 4. `builder.py` — 通用构建引擎（替代 single_distro.py + main.py 中的 build 函数）

```python
import asyncio, os
import dagger
from dagger import dag, DaggerError
from env import BuildEnv
from config import ImageSpec, IMAGE_SPECS
from install import resolve_step, arch_of
from publish import create_push_task

_SPEC_BY_TIER: dict[str, ImageSpec] = {s.tier: s for s in IMAGE_SPECS}

async def fetch_image_exists(env, ref, platform, max_retries=3): ...

def _resolve(template: str, distro: str) -> str:
    return template.format(distro=distro) if "{distro}" in template else template

def _registry_auth(reg):
    """返回 Dagger .with_() 回调（需要 Dagger，放在方法层而非数据层）"""
    secret = dag.set_secret(reg.secret_name, os.environ.get(reg.password_env, ""))
    def _auth(ctr): return ctr.with_registry_auth(reg.address, reg.username, secret)
    return _auth

def _registry_repo(reg, image_name, tag):
    return f"{reg.address}/{reg.username}/{image_name}:{tag}"

async def ensure_image(env: BuildEnv, spec: ImageSpec, distro: str) -> None:
    """构建一个镜像，自动递归确保依赖已构建"""
    ...

def _build_single(env, spec, distro, platform, tg) -> dagger.Container:
    """构建单平台变体并推送到所有 registry（迭代 env.registries）"""
    ...

def _create_manifests(env, variants, image_name, tg) -> None:
    """为所有 registry 创建多架构 manifest（写一次，不再重复）"""
    ...

async def create_manifests_only(env, spec, distro) -> None:
    """Manifest-only 模式"""
    ...
```

**设计要点：**
- `ensure_image` 是唯一的构建入口，递归解决依赖（对 3 节点链，递归深度最多 2）
- `_build_single` 替代了 `build_single_image` + `finish_single_image`，迭代 registries 而非硬编码
- `_create_manifests` 替代了两处重复的 manifest 逻辑
- `_registry_auth` / `_registry_repo` 作为方法层的辅助函数，让 `RegistryConfig` 保持纯数据
- 当前 main.py 中 3 个 build_xxx_image + manifest_my_image_only ≈ 120 行 → 被通用引擎替代

---

### 5. `main.py` — 入口（大幅简化）

```python
import os, sys, asyncio
import dagger
from datetime import datetime
from zoneinfo import ZoneInfo
from config import REGISTRIES, IMAGE_SPECS
from env import BuildEnv
from builder import ensure_image, create_manifests_only

def create_env_from_os() -> BuildEnv:
    # 所有 env var 解析集中于此
    ...

async def main():
    cfg = dagger.Config(log_output=sys.stderr)
    async with dagger.connection(cfg):
        env = create_env_from_os()
        for spec in IMAGE_SPECS:
            if not env.rebuild.get(spec.tier, True):
                continue
            for distro in env.distros:
                if env.manifest_only:
                    await create_manifests_only(env, spec, distro)
                else:
                    await ensure_image(env, spec, distro)
```

### 6. `publish.py` — 不变

已经足够干净，`publish_with_retry` 和 `create_push_task` 都是通用的。

---

## 变更对比

| 指标 | 重构前 | 重构后 |
|------|--------|--------|
| 文件数 | 6 | 6（不同文件） |
| 重复 build 函数 | 3 个 | 1 个通用 `ensure_image` |
| 重复 install 函数 | 3 个 | 1 个 `resolve_step` |
| Manifest 逻辑 | 2 处 | 1 处 |
| 新增 tier 需改动 | 3+ 个文件 | 仅 `config.py` |
| 新增 registry 需改动 | 4+ 处 | 仅 `config.py` 一行 |
| Star imports | 全部 | 0 |
| 废弃参数 | `install_protobuf(_1,_2)` | 无 |

---

## 验证方法

1. **语法验证**：`python -m ast` 检查各文件
2. **数据验证**：对比 `config.py` 与原 `install_pkgs.py` 的包列表确保一致
3. **单 distro 单平台**：`TARGET_DISTROS=humble TARGET_PLATFORMS=linux/amd64` 完整构建
4. **全量验证**：3 distro × 2 platform，对比镜像 layer 与重构前一致

---

## 扩展示例

### 新增 "sim" tier（Gazebo 仿真环境）

只需在 `config.py` 中添加：

```python
SIM_PKGS: list[str] = [f"ros-{distro}-gazebo-ros-pkgs", ...]

IMAGE_SPECS.append(ImageSpec(
    tier="sim",
    image_name_template="{distro}-sim",
    base_image_template="sshawn/{distro}-desktop",
    base_tag_template="",
    steps=(AptStep(static_pkgs=SIM_PKGS),),
    depends_on="desktop",
))
```

然后在 GitHub Actions workflow 中加 `REBUILD_SIM` 环境变量。构建引擎、推送、manifest 全部自动适配。

### 新增 GHCR registry

只需在 `config.py` 的 `REGISTRIES` 中添加一行：

```python
RegistryConfig("ghcr.io", "sshawn9", "GHCR_TOKEN", "ghcr-secret"),
```

所有镜像自动推送到 GHCR，零逻辑改动。
