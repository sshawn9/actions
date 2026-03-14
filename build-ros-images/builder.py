import os
import asyncio

import dagger
from dagger import dag, DaggerError

from config import ImageSpec, IMAGE_SPECS
from env import BuildEnv
from install import resolve_step, arch_of
from publish import create_push_task


_SPEC_BY_TIER: dict[str, ImageSpec] = {s.tier: s for s in IMAGE_SPECS}


def _resolve(template: str, distro: str) -> str:
    '''
    If the template contains "{distro}", replace it with distro; otherwise return the template as is.
    '''
    return template.format(distro=distro) if "{distro}" in template else template


def _registry_repo(reg, image_name: str, tag: str) -> str:
    '''
    Given a registry config, image name and tag, return the full repository reference.

    For example, if reg.address is "ghcr.io/sshawn9", reg.username is "sshawn9",
    image_name is "ros-desktop" and tag is "noetic-amd64", the result would be
    "ghcr.io/sshawn9/sshawn9/ros-desktop:noetic-amd64".
    '''
    return f"{reg.address}/{reg.username}/{image_name}:{tag}"


def _registry_auth(reg):
    """返回一个 Dagger .with_() 回调，用于添加 registry 认证"""
    secret = dag.set_secret(reg.secret_name, os.environ.get(reg.password_env, ""))
    def _auth(ctr: dagger.Container) -> dagger.Container:
        return ctr.with_registry_auth(reg.address, reg.username, secret)
    return _auth


async def fetch_image_exists(
    env: BuildEnv,
    ref: str,
    platform: dagger.Platform,
    max_retries: int = 3,
) -> dagger.Container | None:
    ctr = dag.container(platform=platform)
    for reg in env.registries:
        ctr = ctr.with_(_registry_auth(reg))
    ctr = ctr.from_(ref)

    for attempt in range(1, max_retries + 1):
        try:
            print(f"Checking image {ref} (Attempt {attempt}/{max_retries})...")
            await ctr.id()
            return ctr
        except DaggerError as e:
            print(f"Failed to pull {ref}: {e}")
            if attempt < max_retries:
                print("Retrying in 2 seconds...")
                await asyncio.sleep(2)
    return None


async def ensure_image(env: BuildEnv, spec: ImageSpec, distro: str) -> None:
    """构建一个镜像，自动递归确保依赖已构建"""
    if not env.rebuild.get(spec.tier, True):
        return

    base_ref = _resolve(spec.base_image_template, distro)
    base_tag = _resolve(spec.base_tag_template, distro)

    if spec.depends_on:
        dep_spec = _SPEC_BY_TIER[spec.depends_on]
        for platform in env.platforms:
            tag = base_tag or arch_of(platform)
            if await fetch_image_exists(env, f"{base_ref}:{tag}", platform) is None:
                print(f"Dependency {dep_spec.tier} not found, building first...")
                await ensure_image(env, dep_spec, distro)
                break
    else:
        for platform in env.platforms:
            tag = base_tag or arch_of(platform)
            if await fetch_image_exists(env, f"{base_ref}:{tag}", platform) is None:
                raise RuntimeError(f"Base image {base_ref}:{tag} not found")

    image_name = _resolve(spec.image_name_template, distro)
    async with asyncio.TaskGroup() as tg:
        variants = [_build_single(env, spec, distro, p, tg) for p in env.platforms]
        _create_manifests(env, variants, image_name, tg)


def _build_single(
    env: BuildEnv,
    spec: ImageSpec,
    distro: str,
    platform: dagger.Platform,
    tg: asyncio.TaskGroup,
) -> dagger.Container:
    """构建单平台变体并推送到所有 registry"""
    base_ref = _resolve(spec.base_image_template, distro)
    base_tag = _resolve(spec.base_tag_template, distro)
    image_name = _resolve(spec.image_name_template, distro)

    ctr = (
        dag.container(platform=platform)
        .from_(f"{base_ref}:{base_tag or arch_of(platform)}")
        .with_label("org.opencontainers.image.created", env.created)
        .with_label("org.opencontainers.image.version", env.build_date)
    )
    for step in spec.steps:
        ctr = ctr.with_(resolve_step(step, distro, platform))

    arch = arch_of(platform)
    for reg in env.registries:
        create_push_task(
            tg, ctr,
            _registry_repo(reg, image_name, arch),
            _registry_auth(reg),
            platform_variants=None,
            sem=env.sem,
        )
    return ctr


def _create_manifests(
    env: BuildEnv,
    variants: list[dagger.Container],
    image_name: str,
    tg: asyncio.TaskGroup,
) -> None:
    """为所有 registry 创建多架构 manifest"""
    if len(variants) < 2:
        return
    main, others = variants[0], variants[1:]
    for reg in env.registries:
        for tag in (env.manifest_tag, "latest"):
            create_push_task(
                tg, main,
                _registry_repo(reg, image_name, tag),
                _registry_auth(reg),
                platform_variants=others,
                sem=env.sem,
            )


async def create_manifests_only(env: BuildEnv, spec: ImageSpec, distro: str) -> None:
    """Manifest-only 模式：收集已有镜像并创建 manifest"""
    image_name = _resolve(spec.image_name_template, distro)
    async with asyncio.TaskGroup() as tg:
        for reg in env.registries:
            variants: list[dagger.Container] = []
            for platform in env.platforms:
                ref = _registry_repo(reg, image_name, arch_of(platform))
                if await fetch_image_exists(env, ref, platform) is not None:
                    variants.append(
                        dag.container(platform=platform).from_(ref)
                    )
            if len(variants) >= 2:
                main, others = variants[0], variants[1:]
                for tag in (env.manifest_tag, "latest"):
                    create_push_task(
                        tg, main,
                        _registry_repo(reg, image_name, tag),
                        _registry_auth(reg),
                        platform_variants=others,
                        sem=env.sem,
                    )
