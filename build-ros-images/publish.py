from collections.abc import Callable

from base import *

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

def create_push_task(
    tg: asyncio.TaskGroup,
    ctr: dagger.Container,
    ref: str,
    auth: Callable[[dagger.Container], dagger.Container],
    *,
    platform_variants: list[dagger.Container] | None,
    sem: asyncio.Semaphore,
) -> None:
    vs = [ v.with_(auth) for v in (platform_variants or []) ] or None
    tg.create_task(publish_with_retry(
        ctr.with_(auth), ref, platform_variants=vs, sem=sem,
    ))
