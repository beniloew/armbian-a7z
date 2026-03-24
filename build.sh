#!/bin/bash
# Wrapper for Armbian build (Orange Pi 5 / opi5 branch helpers)
#
# Usage:
#   ./build.sh build BOARD=orangepi5b BRANCH=current BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no
#
# Options:
#   BUILD_VERSION=dev ./build.sh ...                     # version profile (default: dev)
#   ARMBIAN_PRESET_ROOT_PASSWORD=secret ./build.sh ...   # root password (overrides default 1234 in the image)
#   DOCKER_SKIP=yes ./build.sh ...                       # native build (no Docker)

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

source ./compile.sh "$@"
