from single_distro import *
from install_pkgs import *


async def fetch_image_exists(
    env: BuildEnv,
    ref: str,
    platform: dagger.Platform,
    max_retries: int = 3,
) -> dagger.Container | None:
    ctr = (
        dag.container(platform=platform)
        .with_(env.dh_auth).with_(env.ali_auth).from_(ref)
    )
    for attempt in range(1, max_retries + 1):
        try:
            print(f"Checking image {ref} (Attempt {attempt}/{max_retries})...")
            await ctr.id()
            return ctr
        except DaggerError as e:
            print(f"Failed to pull {ref}: {e}")
            print("Retrying in 2 seconds...")
            await asyncio.sleep(2)
    return None

async def build_base_image(
    env: BuildEnv,
    distro: str,
):
    base_image = "ros"
    base_image_tag = f"{distro}"
    image_name = f"{distro}"
    middle_fns = [
        install_base_for
    ]
    for platform in env.platforms:
        if await fetch_image_exists(
            env,
            f"{base_image}:{base_image_tag or arch_of(platform)}",
            platform,
        ) is not None:
            continue
        sys.exit('Ros image not found, unbelievable...')
    async with asyncio.TaskGroup() as tg:
        build_single_distro(env, distro, base_image, base_image_tag, image_name, tg, middle_fns)

async def build_desktop_image(
    env: BuildEnv,
    distro: str,
):
    base_image = f"sshawn/{distro}"
    base_image_tag = ""
    image_name = f"{distro}-desktop"
    middle_fns = [
        install_desktop_for
    ]
    for platform in env.platforms:
        if await fetch_image_exists(
            env,
            f"{base_image}:{base_image_tag or arch_of(platform)}",
            platform,
        ) is not None:
            continue
        print("building base image first...")
        await build_base_image(env, distro)
    async with asyncio.TaskGroup() as tg:
        build_single_distro(env, distro, base_image, base_image_tag, image_name, tg, middle_fns)

async def build_box_image(
    env: BuildEnv,
    distro: str,
):
    base_image = f"sshawn/{distro}-desktop"
    base_image_tag = ""
    image_name = f"{distro}-box"
    middle_fns = [
        install_box_for
    ]
    for platform in env.platforms:
        if await fetch_image_exists(
            env,
            f"{base_image}:{base_image_tag or arch_of(platform)}",
            platform,
        ) is not None:
            continue
        print("building desktop image first...")
        await build_desktop_image(env, distro)
    async with asyncio.TaskGroup() as tg:
        build_single_distro(env, distro, base_image, base_image_tag, image_name, tg, middle_fns)

async def manifest_my_image_only(env: BuildEnv, image_name: str):
    async with asyncio.TaskGroup() as tg:
        dh_variants: list[dagger.Container] = []
        for platform in env.platforms:
            if await fetch_image_exists(
                env,
                env.dh_repo(image_name, arch_of(platform)),
                platform,
            ) is None:
                continue
            dh_variants.append(
                dag.container(platform=platform)
                .from_(f"{env.dh_repo(image_name, arch_of(platform))}")
            )
        if len(dh_variants) >= 2:
            main_variant = dh_variants[0]
            others = dh_variants[1:] or None
            for tag in (env.manifest_tag, "latest"):
                create_push_task(
                    tg,
                    main_variant,
                    env.dh_repo(image_name, tag),
                    env.dh_auth,
                    platform_variants=others,
                    sem=env.sem,
                )

        ali_variants = []
        for platform in env.platforms:
            if await fetch_image_exists(
                env,
                env.ali_repo(image_name, arch_of(platform)),
                platform,
            ) is None:
                continue
            ali_variants.append(
                dag.container(platform=platform)
                .from_(f"{env.ali_repo(image_name, arch_of(platform))}")
            )
        if len(ali_variants) >= 2:
            main_variant = ali_variants[0]
            others = ali_variants[1:] or None
            for tag in (env.manifest_tag, "latest"):
                create_push_task(
                    tg,
                    main_variant,
                    env.ali_repo(image_name, tag),
                    env.ali_auth,
                    platform_variants=others,
                    sem=env.sem,
                )

def create_env_from_os() -> BuildEnv:
    distros = ["noetic", "humble", "jazzy"]
    td = os.environ.get("TARGET_DISTROS", "").strip()
    if td:
        distros = [x.strip() for x in td.split(",") if x.strip()]
    platforms = [dagger.Platform("linux/amd64"), dagger.Platform("linux/arm64")]
    tp = os.environ.get("TARGET_PLATFORMS", "").strip()
    if tp:
        platforms = [dagger.Platform(x.strip()) for x in tp.split(",") if x.strip()]
    env = BuildEnv(
        distros=distros,
        platforms=platforms,
    )
    return env

async def build_workflow(env: BuildEnv):
    if env.manifest_only:
        return
    for distro in env.distros:
        if env.rebuild_base:
            await build_base_image(env, distro)
        if env.rebuild_desktop:
            await build_desktop_image(env, distro)
        if env.rebuild_box:
            await build_box_image(env, distro)

async def manifest_workflow(env: BuildEnv):
    if not env.manifest_only:
        return
    for distro in env.distros:
        if env.rebuild_base:
            await manifest_my_image_only(env, distro)
        if env.rebuild_desktop:
            await manifest_my_image_only(env, f"{distro}-desktop")
        if env.rebuild_box:
            await manifest_my_image_only(env, f"{distro}-box")

async def main():
    cfg = dagger.Config(log_output=sys.stderr)
    async with dagger.connection(cfg):
        env = create_env_from_os()
        await build_workflow(env)
        await manifest_workflow(env)


if __name__ == "__main__":
    asyncio.run(main())
