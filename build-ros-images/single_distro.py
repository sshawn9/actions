from typing import Callable
from base import *
from publish import *


def finish_single_image(
    env: BuildEnv,
    ctr: dagger.Container,
    image_name: str,
    platform: dagger.Platform,
    tg: asyncio.TaskGroup
) -> dagger.Container:
    arch = arch_of(platform)
    create_push_task(
        tg,
        ctr,
        env.dh_repo(image_name, arch),
        env.dh_auth,
        platform_variants=None, sem=env.sem,
    )
    create_push_task(
        tg,
        ctr,
        env.ali_repo(image_name, arch),
        env.ali_auth,
        platform_variants=None, sem=env.sem,
    )
    return ctr

def build_single_image(
    env: BuildEnv,
    distro: str,
    base_image: str,
    base_image_tag: str, # if empty, use platform arch
    image_name: str,
    platform: dagger.Platform,
    tg: asyncio.TaskGroup,
    middle_fns: list[Callable],
) -> dagger.Container:
    ctr = (
        dag.container(platform=platform)
        .from_(f"{base_image}:{base_image_tag or arch_of(platform)}")
        .with_label("org.opencontainers.image.created", env.created)
        .with_label("org.opencontainers.image.version", env.build_date)
    )
    for fn in middle_fns:
        ctr = ctr.with_(fn(distro, platform))
    ctr = finish_single_image(env, ctr, image_name, platform, tg)
    return ctr

def build_single_distro(
    env: BuildEnv,
    distro: str,
    base_image: str,
    base_image_tag: str, # if empty, use platform arch
    image_name: str,
    tg: asyncio.TaskGroup,
    middle_fns: list[Callable],
) -> list[dagger.Container]:
    variants: list[dagger.Container] = []
    for platform in env.platforms:
        variants.append(
            build_single_image(
                env, distro, base_image, base_image_tag, image_name, platform, tg, middle_fns,
            )
        )
    if len(variants) < 2:
        return variants
    main = variants[0]
    others = variants[1:] or None
    for tag in (env.manifest_tag, "latest"):
        create_push_task(
            tg,
            main,
            env.dh_repo(image_name, tag),
            env.dh_auth,
            platform_variants=others,
            sem=env.sem,
        )
        create_push_task(
            tg,
            main,
            env.ali_repo(image_name, tag),
            env.ali_auth,
            platform_variants=others,
            sem=env.sem,
        )
    return variants
