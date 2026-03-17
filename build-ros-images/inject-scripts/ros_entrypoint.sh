#!/bin/sh
set -e

# Source ROS setup using the POSIX-compatible variant.
# This works regardless of which shell will be exec'd next.
. "/opt/ros/$ROS_DISTRO/setup.sh"

exec "$@"
