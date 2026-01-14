import dagger

from single_distro import *
from install_pkgs import *


async def fetch_image(
    ref: str,
    platform: dagger.Platform,
    max_retries: int = 3,
    fn: Callable = None,
) -> dagger.Container:
    for attempt in range(1, max_retries + 1):
        try:
            print(f"Checking image {ref} (Attempt {attempt}/{max_retries})...")
            ctr = dag.container(platform=platform).from_(ref)
            await ctr.id()
            return ctr
        except DaggerError as e:
            print(f"Failed to pull {ref}: {e}")
            if fn is not None:
                print(f"Attempting to build missing image {ref}...")
                await fn()
            if attempt == max_retries:
                sys.exit(f"Exceeded maximum retries for {ref}. Exiting.")
            print("Retrying in 2 seconds...")
            await asyncio.sleep(2)
    raise Exception("Unreachable")

async def build_base_image(
    env: BuildEnv,
    distro: str,
    tg: asyncio.TaskGroup,
):
    base_image = "ros"
    base_image_tag = f"{distro}"
    image_name = f"{distro}"
    middle_fns = [
        install_base_for
    ]
    for platform in env.platforms:
        await fetch_image(
            base_image,
            platform,
        )
    build_single_distro(env, distro, base_image, base_image_tag, image_name, tg, middle_fns)

async def build_desktop_image(
    env: BuildEnv,
    distro: str,
    tg: asyncio.TaskGroup,
):
    base_image = f"sshawn/{distro}"
    image_name = f"{distro}-desktop"
    middle_fns = [
        install_desktop_for
    ]
    for platform in env.platforms:
        await fetch_image(
            base_image,
            platform,
            fn=lambda: build_base_image(env, distro, tg),
        )
    build_single_distro(env, distro, base_image, "", image_name, tg, middle_fns)

async def build_box_image(
    env: BuildEnv,
    distro: str,
    tg: asyncio.TaskGroup,
):
    base_image = f"sshawn/{distro}-desktop"
    image_name = f"{distro}-box"
    middle_fns = [
        install_box_for
    ]
    for platform in env.platforms:
        await fetch_image(
            base_image,
            platform,
            fn=lambda: build_desktop_image(env, distro, tg),
        )
    build_single_distro(env, distro, base_image, "", image_name, tg, middle_fns)

async def manifest_my_image_only(env: BuildEnv, image_name: str, tg: asyncio.TaskGroup):
    dh_variants: list[dagger.Container] = []
    for platform in env.platforms:
        await fetch_image(
            env.dh_repo(image_name, arch_of(platform)),
            platform,
        )
        dh_variants.append(
            dag.container(platform=platform)
            .from_(f"{env.dh_repo(image_name, arch_of(platform))}")
        )
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
        await fetch_image(
            env.ali_repo(image_name, arch_of(platform)),
            platform,
        )
        ali_variants.append(
            dag.container(platform=platform)
            .from_(f"{env.ali_repo(image_name, arch_of(platform))}")
        )
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
        manifest_only=os.environ.get("MANIFEST_ONLY") == "1",
        custom_manifest_tag=os.environ.get("MANIFEST_TAG", "")
    )
    return env

async def build_workflow(env: BuildEnv):
    for distro in env.distros:
        if env.rebuild_base:
            async with asyncio.TaskGroup() as tg:
                await build_base_image(env, distro, tg)
        if env.rebuild_desktop:
            async with asyncio.TaskGroup() as tg:
                await build_desktop_image(env, distro, tg)
        if env.rebuild_box:
            async with asyncio.TaskGroup() as tg:
                await build_box_image(env, distro, tg)

async def manifest_workflow(env: BuildEnv):
    for distro in env.distros:
        if env.rebuild_base:
            async with asyncio.TaskGroup() as tg:
                await manifest_my_image_only(env, distro, tg)
        if env.rebuild_desktop:
            async with asyncio.TaskGroup() as tg:
                await manifest_my_image_only(env, f"{distro}-desktop", tg)
        if env.rebuild_box:
            async with asyncio.TaskGroup() as tg:
                await manifest_my_image_only(env, f"{distro}-box", tg)

async def main():
    cfg = dagger.Config(log_output=sys.stderr)
    async with dagger.connection(cfg):
        env = create_env_from_os()
        if env.manifest_only:
            await manifest_workflow(env)
            return
        await build_workflow(env)


if __name__ == "__main__":
    asyncio.run(main())
