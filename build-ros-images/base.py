import os
import sys
import shlex
import textwrap
import asyncio
from dataclasses import dataclass, field
from datetime import datetime
from zoneinfo import ZoneInfo
import dagger
from dagger import dag
from dagger import DaggerError

def arch_of(platform: dagger.Platform) -> str:
    return str(platform).split("/")[-1]


@dataclass
class BuildEnv:
    distros: list[str]
    platforms: list[dagger.Platform]
    manifest_only: bool
    custom_manifest_tag: str

    docker_addr: str = "docker.io"
    ali_addr: str = "registry.cn-beijing.aliyuncs.com"
    username: str = "sshawn"
    dh_pass: dagger.Secret = dag.set_secret("dh-secret", os.environ.get("DOCKERHUB_PASSWORD", ""))
    ali_pass: dagger.Secret = dag.set_secret("ali-secret", os.environ.get("ALIYUN_PASSWORD", ""))
    build_date: str = datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y%m%d")
    created: str = datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(timespec="seconds")
    sem: asyncio.Semaphore = field(default_factory=lambda: asyncio.Semaphore(1))

    @property
    def manifest_tag(self) -> str:
        return self.custom_manifest_tag or self.build_date

    def dh_repo(self, image_name: str, tag: str) -> str:
        return f"{self.docker_addr}/{self.username}/{image_name}:{tag}"
    def ali_repo(self, image_name: str, tag: str) -> str:
        return f"{self.ali_addr}/{self.username}/{image_name}:{tag}"
    def dh_auth(self, ctr: dagger.Container) -> dagger.Container:
        return ctr.with_registry_auth(self.docker_addr, self.username, self.dh_pass)
    def ali_auth(self, ctr: dagger.Container) -> dagger.Container:
        return ctr.with_registry_auth(self.ali_addr, self.username, self.ali_pass)
