#!/usr/bin/env bash
# Install gpio-service on the target board (e.g. Radxa Cubie A7Z).
# Requires Linux GPIO character devices (/dev/gpiochip*). Run on the device: sudo ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${GPIO_SERVICE_ROOT:-/opt/gpio-service}"
ENABLE=1
START=1

usage() {
	cat <<EOF
Usage: sudo $0 [options]

Installs ${INSTALL_ROOT}, creates a Python venv, installs python-periphery, and
installs systemd unit gpio.service.

Options:
  --prefix=PATH   Install under PATH (default: /opt/gpio-service).
                  Same as env GPIO_SERVICE_ROOT.
  --no-enable     Do not run systemctl enable gpio.service
  --no-start      Do not run systemctl start gpio.service
  -h, --help      Show this help

Environment:
  GPIO_SERVICE_ROOT   Same as --prefix
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--prefix=*)
		INSTALL_ROOT="${1#*=}"
		;;
	--no-enable)
		ENABLE=0
		;;
	--no-start)
		START=0
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		usage >&2
		exit 1
		;;
	esac
	shift
done

if [[ "$(id -u)" -ne 0 ]]; then
	echo "Run as root (e.g. sudo $0)" >&2
	exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
	echo "python3 is required" >&2
	exit 1
fi

echo "Installing to ${INSTALL_ROOT}"

mkdir -p "${INSTALL_ROOT}"
install -m 0644 "${SCRIPT_DIR}/gpio_service.py" "${INSTALL_ROOT}/gpio_service.py"
install -m 0644 "${SCRIPT_DIR}/requirements.txt" "${INSTALL_ROOT}/requirements.txt"

if [[ ! -d "${INSTALL_ROOT}/venv" ]]; then
	python3 -m venv "${INSTALL_ROOT}/venv"
fi

"${INSTALL_ROOT}/venv/bin/pip" install --upgrade pip -q
"${INSTALL_ROOT}/venv/bin/pip" install -r "${INSTALL_ROOT}/requirements.txt"

sed "s|/opt/gpio-service|${INSTALL_ROOT}|g" "${SCRIPT_DIR}/gpio.service" \
	>/etc/systemd/system/gpio.service

systemctl daemon-reload

if [[ "${ENABLE}" -eq 1 ]]; then
	systemctl enable gpio.service
	echo "Enabled gpio.service"
else
	echo "Skipped systemctl enable (use --no-enable)"
fi

if [[ "${START}" -eq 1 ]]; then
	systemctl restart gpio.service
	echo "Started gpio.service"
else
	echo "Skipped systemctl start (use --no-start)"
fi

echo "Done. Logs: journalctl -u gpio.service -f"
