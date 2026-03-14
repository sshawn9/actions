import os
import sys
import asyncio
from datetime import datetime
from zoneinfo import ZoneInfo

import dagger

from config import REGISTRIES, IMAGE_SPECS
from env import BuildEnv
from builder import ensure_image, create_manifests_only


def create_env_from_os() -> BuildEnv:
    distros = ["noetic", "humble", "jazzy"]
    td = os.environ.get("TARGET_DISTROS", "").strip()
    if td:
        distros = [x.strip() for x in td.split(",") if x.strip()]

    platforms = [dagger.Platform("linux/amd64"), dagger.Platform("linux/arm64")]
    tp = os.environ.get("TARGET_PLATFORMS", "").strip()
    if tp:
        platforms = [dagger.Platform(x.strip()) for x in tp.split(",") if x.strip()]

    now = datetime.now(ZoneInfo("Asia/Shanghai"))

    return BuildEnv(
        distros=distros,
        platforms=platforms,
        registries=REGISTRIES,
        manifest_only=os.environ.get("MANIFEST_ONLY", "0") == "1",
        manifest_tag=os.environ.get("MANIFEST_TAG", "") or now.strftime("%Y%m%d"),
        build_date=now.strftime("%Y%m%d"),
        created=now.isoformat(timespec="seconds"),
        rebuild={
            "base": os.environ.get("REBUILD_BASE", "1") == "1",
            "desktop": os.environ.get("REBUILD_DESKTOP", "1") == "1",
            "box": os.environ.get("REBUILD_BOX", "1") == "1",
        },
    )


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


if __name__ == "__main__":
    asyncio.run(main())
