#!/bin/bash

set -e

sudo=$( [ "$(id -u)" -ne 0 ] && echo "sudo" || echo "" )

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$self_dir"

function _control_install_protobuf {
    if [ -f /usr/local/bin/protoc ]; then
        if /usr/local/bin/protoc --version 2>/dev/null | grep -q "libprotoc 3.21.5"; then
            echo "Protobuf 3.21.5 is already installed."
            return 0
        fi
    fi

    $sudo apt-get update
    $sudo apt-get install --no-install-recommends -y autoconf \
                                                     automake \
                                                     libtool \
                                                     curl \
                                                     make \
                                                     g++ \
                                                     unzip \
                                                     wget

    #protobuf_kkgithub=https://kkgithub.com/protocolbuffers/protobuf/releases/download/v21.5/protobuf-all-21.5.tar.gz
    protobuf_github=https://github.com/protocolbuffers/protobuf/releases/download/v21.5/protobuf-all-21.5.tar.gz

    set +e
    # if [ ! -f "$self_dir"/protobuf-all-21.5.tar.gz ]; then
    #     #wget -t 5 --connect-timeout=10 --read-timeout=10 "$protobuf_kkgithub"
    #     wget -t 10 "$protobuf_kkgithub"
    # fi
    if [ ! -f "$self_dir"/protobuf-all-21.5.tar.gz ]; then
        #wget -t 5 --connect-timeout=10 --read-timeout=10 "$protobuf_github"
        wget -t 10 "$protobuf_github"
    fi
    set -e
    if [ ! -f "$self_dir"/protobuf-all-21.5.tar.gz ]; then
        echo "Failed to download protobuf-all-21.5.tar.gz"
        return 1
    fi
    rm -rf protobuf_install
    mkdir protobuf_install
    tar -xzf protobuf-all-21.5.tar.gz -C protobuf_install
    cd protobuf_install/protobuf*
    ./configure
    make -j$(nproc)
    #make -j$(($(nproc) > 8 ? 8 : $(nproc)))
    #make check
    $sudo make install
    $sudo ldconfig
    cd ../..
    rm -rf protobuf_install
    rm -f protobuf-all-21.5.tar.gz
}

_control_install_protobuf
