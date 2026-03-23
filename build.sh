#!/bin/bash
# Wrapper for Armbian build (Orange Pi 5 / opi5 branch helpers)
#
# Usage:
#   ./build.sh build BOARD=orangepi5 BRANCH=current BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no
#
# Options:
#   ARMBIAN_PRESET_ROOT_PASSWORD=secret ./build.sh ...   # root password (overrides default 1234 in the image)
#   DOCKER_SKIP=yes ./build.sh ...                       # native build (no Docker)
#

declare -a DOCKER_EXTRA_ARGS=("--env" "PESTER_TERMINAL=no")
if [[ -n "${ARMBIAN_PRESET_ROOT_PASSWORD:-}" ]]; then
	DOCKER_EXTRA_ARGS+=("--env" "ARMBIAN_PRESET_ROOT_PASSWORD=${ARMBIAN_PRESET_ROOT_PASSWORD}")
fi

source ./compile.sh "$@"
