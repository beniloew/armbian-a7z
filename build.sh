#!/bin/bash
# Wrapper for Armbian build with custom settings for Radxa Cubie A7Z
#
# Usage:
#   ./build.sh build BOARD=radxa-cubie-a7z BRANCH=legacy BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no RELEASE=bookworm
#
# Options:
#   A7Z_ROOTPWD=mypass ./build.sh ...    # custom root password
#   DOCKER_SKIP=yes ./build.sh ...       # build natively (skip Docker)
#   RADXA_OVERLAYS_VERSION=0.2.19 ./build.sh ...   # Radxa radxa-overlays-dkms deb (default: 0.2.18)
#   DOCKER_SKIP_PULL=yes ./build.sh ...  # do not docker pull; use local Armbian base image only
#

declare -a DOCKER_EXTRA_ARGS=("--env" "PESTER_TERMINAL=no")
[[ -n "${A7Z_ROOTPWD:-}" ]] && DOCKER_EXTRA_ARGS+=("--env" "A7Z_ROOTPWD=${A7Z_ROOTPWD}")
[[ -n "${RADXA_OVERLAYS_VERSION:-}" ]] && DOCKER_EXTRA_ARGS+=("--env" "RADXA_OVERLAYS_VERSION=${RADXA_OVERLAYS_VERSION}")

source ./compile.sh "$@"
