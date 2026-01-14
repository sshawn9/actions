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
    *,
    platform_variants: list[dagger.Container] | None,
    sem: asyncio.Semaphore,
) -> None:
    tg.create_task(publish_with_retry(
        ctr, ref, platform_variants=platform_variants, sem=sem,
    ))
