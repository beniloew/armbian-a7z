#!/bin/bash
# Wrapper for Armbian build (Orange Pi 5 + Radxa Cubie A7Z)
#
# Usage:
#   ./build.sh build BOARD=orangepi5b BRANCH=current BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no
#   ./build.sh build BOARD=radxa-cubie-a7z BRANCH=legacy BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no RELEASE=bookworm
#
# Options:
#   BUILD_VERSION=dev ./build.sh ...                     # version profile (default: dev)
#   ARMBIAN_PRESET_ROOT_PASSWORD=secret ./build.sh ...   # root password for OPI5 (overrides default 1234)
#   A7Z_ROOTPWD=mypass ./build.sh ...                    # root password for A7Z
#   DOCKER_SKIP=yes ./build.sh ...                       # native build (no Docker)
#   DOCKER_SKIP_PULL=yes ./build.sh ...                  # do not docker pull; use local Armbian base image only
#   RADXA_OVERLAYS_VERSION=0.2.19 ./build.sh ...         # Radxa radxa-overlays-dkms deb (default: 0.2.18)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load version profile ---
BUILD_VERSION="${BUILD_VERSION:-dev}"
VERSION_FILE="${SCRIPT_DIR}/userpatches/versions/${BUILD_VERSION}.conf"
if [[ ! -f "${VERSION_FILE}" ]]; then
	echo "ERROR: version profile '${BUILD_VERSION}' not found at ${VERSION_FILE}" >&2
	exit 1
fi
# shellcheck source=userpatches/versions/dev.conf
source "${VERSION_FILE}"
echo ":: build.sh: loaded version profile '${BUILD_VERSION}' from ${VERSION_FILE}"

# Copy version profile to overlay so customize-image.sh can read it inside chroot
mkdir -p "${SCRIPT_DIR}/userpatches/overlay"
cp "${VERSION_FILE}" "${SCRIPT_DIR}/userpatches/overlay/build-versions.conf"

# InstallGpioService (customize-image.sh) only runs if /tmp/overlay/gpio-service exists in chroot
rm -rf "${SCRIPT_DIR}/userpatches/overlay/gpio-service"
cp -a "${SCRIPT_DIR}/gpio-service" "${SCRIPT_DIR}/userpatches/overlay/gpio-service"

# --- Docker env passthrough ---
declare -a DOCKER_EXTRA_ARGS=("--env" "PESTER_TERMINAL=no")
if [[ -n "${ARMBIAN_PRESET_ROOT_PASSWORD:-}" ]]; then
	DOCKER_EXTRA_ARGS+=("--env" "ARMBIAN_PRESET_ROOT_PASSWORD=${ARMBIAN_PRESET_ROOT_PASSWORD}")
fi

# Pass version pins to Docker (available to board/family configs)
for _var in PIN_KERNEL_TAG PIN_RTL8812AU_REPO PIN_RTL8812AU_COMMIT PIN_RTL8812AU_BRANCH \
            PIN_WFB_NG_VERSION PIN_GPIOD_VERSION PIN_PYYAML_VERSION; do
	if [[ -n "${!_var:-}" ]]; then
		DOCKER_EXTRA_ARGS+=("--env" "${_var}=${!_var}")
	fi
done

# A7Z-specific env vars
[[ -n "${A7Z_ROOTPWD:-}" ]] && DOCKER_EXTRA_ARGS+=("--env" "A7Z_ROOTPWD=${A7Z_ROOTPWD}")
[[ -n "${RADXA_OVERLAYS_VERSION:-}" ]] && DOCKER_EXTRA_ARGS+=("--env" "RADXA_OVERLAYS_VERSION=${RADXA_OVERLAYS_VERSION}")

source ./compile.sh "$@"
