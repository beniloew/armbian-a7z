#!/bin/bash
# Wrapper for Armbian build with custom settings for Radxa Cubie A7Z
#
# Usage: ./build.sh [compile.sh args...]
#   A7Z_ROOTPWD=mypass ./build.sh    # custom root password
#

declare -a DOCKER_EXTRA_ARGS=("--env" "PESTER_TERMINAL=no")
[[ -n "${A7Z_ROOTPWD:-}" ]] && DOCKER_EXTRA_ARGS+=("--env" "A7Z_ROOTPWD=${A7Z_ROOTPWD}")

source ./compile.sh "$@"
