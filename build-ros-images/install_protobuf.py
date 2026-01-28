from base import *


def install_protobuf(
    _1, _2,
):
    def _fn(container: dagger.Container) -> dagger.Container:
        script = dag.host().file("inject-scripts/install_protobuf.sh")
        return (
            container
            .with_mounted_file("/tmp/install_protobuf.sh", script)
            .with_exec(["bash", "-lc", "chmod +x /tmp/install_protobuf.sh"])
            .with_exec(["bash", "-lc", "/tmp/install_protobuf.sh"])
        )
