from base import *


def install_protobuf(
    ctr: dagger.Container
):
    script = dag.host().file("inject-scripts/install_protobuf.sh")
    return (
        ctr
        .with_mounted_file("/tmp/install_protobuf.sh", script)
        .with_exec(["bash", "-lc", "chmod +x /tmp/install_protobuf.sh"])
        .with_exec(["bash", "-lc", "/tmp/install_protobuf.sh"])
    )
