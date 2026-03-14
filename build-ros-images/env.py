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
    rebuild: dict[str, bool]
    sem: asyncio.Semaphore = field(default_factory=lambda: asyncio.Semaphore(1))
