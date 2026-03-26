#!/usr/bin/env python3
"""Add or remove a static IP on a remote device's ethernet interface.

Usage:
    # Query only — show current ethernet config
    ./add-static-ip.py root@192.168.100.246 --query

    # Interactive — prompt before applying
    ./add-static-ip.py root@192.168.100.246 --ip 192.168.101.1

    # Remove a previously added static IP (undo)
    ./add-static-ip.py root@192.168.100.246 --remove 192.168.101.1

    # From YAML config — no prompt
    ./add-static-ip.py root@192.168.100.246 --config static-ip.yaml

YAML config example (add):
    ip: 192.168.101.1
    prefix: 17          # optional, detected from current connection
    gateway: 192.168.0.1  # optional, detected
    dns: 192.168.0.1      # optional, detected

YAML config example (remove):
    remove: true
    ip: 192.168.101.1
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None


def ssh_run(target: str, cmd: str) -> str:
    result = subprocess.run(
        ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10", target, cmd],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"SSH command failed: {result.stderr.strip()}")
    return result.stdout.strip()


def query_connection(target: str) -> dict:
    """Fetch ethernet connection details from the remote device."""
    raw = ssh_run(target, " && ".join([
        'CON=$(nmcli -t -f NAME,TYPE,DEVICE con show --active | grep ethernet | head -1)',
        'CON_NAME="${CON%%:*}"',
        'echo "___CON_NAME=${CON_NAME}"',
        'nmcli -t -f IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,ipv4.method,ipv4.addresses '
        'con show "${CON_NAME}"',
        'echo "___DEVICE=$(echo "${CON}" | cut -d: -f3)"',
        'echo "___MAC=$(cat /sys/class/net/$(echo "${CON}" | cut -d: -f3)/address 2>/dev/null)"',
    ]))

    info = {
        "connection": "", "device": "", "mac": "",
        "method": "", "dhcp_addresses": [], "static_addresses": [],
        "gateway": "", "dns": [],
    }

    for line in raw.splitlines():
        if line.startswith("___CON_NAME="):
            info["connection"] = line.split("=", 1)[1]
        elif line.startswith("___DEVICE="):
            info["device"] = line.split("=", 1)[1]
        elif line.startswith("___MAC="):
            info["mac"] = line.split("=", 1)[1]
        elif line.startswith("IP4.ADDRESS"):
            info["dhcp_addresses"].append(line.split(":", 1)[1])
        elif line.startswith("IP4.GATEWAY"):
            info["gateway"] = line.split(":", 1)[1]
        elif line.startswith("IP4.DNS"):
            info["dns"].append(line.split(":", 1)[1])
        elif line.startswith("ipv4.method"):
            info["method"] = line.split(":", 1)[1]
        elif line.startswith("ipv4.addresses"):
            val = line.split(":", 1)[1].strip()
            if val and val != "--":
                info["static_addresses"] = [a.strip() for a in val.split(",") if a.strip()]

    return info


def print_info(info: dict) -> None:
    print(f"\n  Connection : {info['connection']}")
    print(f"  Device     : {info['device']}")
    print(f"  MAC        : {info['mac']}")
    print(f"  Method     : {info['method']}")
    for addr in info["dhcp_addresses"]:
        print(f"  IP (active): {addr}")
    if info["static_addresses"]:
        for addr in info["static_addresses"]:
            print(f"  IP (static): {addr}")
    print(f"  Gateway    : {info['gateway']}")
    print(f"  DNS        : {', '.join(info['dns'])}")
    print()


def parse_prefix(cidr: str) -> str:
    """Extract prefix length from a CIDR address like '192.168.100.246/17'."""
    if "/" in cidr:
        return cidr.split("/")[1]
    return ""


def add_static_ip(target: str, info: dict, ip: str, prefix: str = "",
                  gateway: str = "", dns: str = "") -> None:
    if not prefix:
        if info["dhcp_addresses"]:
            prefix = parse_prefix(info["dhcp_addresses"][0])
    if not prefix:
        prefix = "24"

    cidr = f"{ip}/{prefix}" if "/" not in ip else ip

    if not gateway:
        gateway = info["gateway"]
    if not dns:
        dns = info["dns"][0] if info["dns"] else ""

    con = info["connection"]

    print(f"  Adding static IP: {cidr}")
    print(f"  Gateway         : {gateway}")
    print(f"  DNS             : {dns}")
    print(f"  Connection      : {con}")
    print()

    parts = [f'nmcli con mod "{con}" +ipv4.addresses "{cidr}"']
    if gateway:
        parts.append(f'nmcli con mod "{con}" ipv4.gateway "{gateway}"')
    if dns:
        parts.append(f'nmcli con mod "{con}" +ipv4.dns "{dns}"')
    parts.append(f'nmcli con up "{con}"')

    ssh_run(target, " && ".join(parts))

    print("  Done. Verifying...")
    new_ip = ip.split("/")[0]
    try:
        out = ssh_run(
            f"{target.split('@')[0]}@{new_ip}",
            f"ip -4 addr show {info['device']} | grep inet",
        )
        print(f"  Reachable at {new_ip}:")
        for line in out.splitlines():
            print(f"    {line.strip()}")
    except RuntimeError:
        print(f"  WARNING: could not reach {new_ip} — verify manually")
    print()


def remove_static_ip(target: str, info: dict, ip: str, skip_prompt: bool = False) -> None:
    """Remove a static IPv4 address from the connection (nmcli -ipv4.addresses)."""
    host = ip.split("/")[0]
    to_remove = [a for a in info["static_addresses"] if a.split("/")[0] == host]
    if not to_remove:
        print(
            f"ERROR: No static address matching '{ip}' on connection '{info['connection']}'.",
            file=sys.stderr,
        )
        sys.exit(1)

    con = info["connection"]
    print(f"  Removing static IP(s): {', '.join(to_remove)}")
    print(f"  Connection            : {con}")
    print()

    if not skip_prompt:
        answer = input("\n  Proceed? [y/N] ").strip().lower()
        if answer != "y":
            print("  Aborted.")
            return

    parts = [f'nmcli con mod "{con}" -ipv4.addresses "{cidr}"' for cidr in to_remove]
    parts.append(f'nmcli con up "{con}"')
    ssh_run(target, " && ".join(parts))
    print("  Done.")
    print()


def load_yaml_config(path: str) -> dict:
    if yaml is None:
        print("ERROR: PyYAML is required for --config. Install with: pip install pyyaml", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        return yaml.safe_load(f)


def main():
    parser = argparse.ArgumentParser(
        description="Add or remove a static IP on a remote device's ethernet interface.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("target", help="SSH target (e.g. root@192.168.100.246)")
    parser.add_argument("--query", action="store_true", help="Only show current config, don't modify")
    parser.add_argument("--ip", help="Static IP to add (e.g. 192.168.101.1)")
    parser.add_argument(
        "--remove",
        metavar="IP",
        help="Remove this static IP from the connection (undo; host or CIDR)",
    )
    parser.add_argument("--prefix", help="Subnet prefix length (default: auto-detect from current)")
    parser.add_argument("--gateway", help="Gateway (default: auto-detect from current)")
    parser.add_argument("--dns", help="DNS server (default: auto-detect from current)")
    parser.add_argument("--config", help="YAML config file with connection details (skips prompt)")
    args = parser.parse_args()

    if args.ip and args.remove:
        parser.error("--ip and --remove cannot be used together")

    print(f"\nQuerying {args.target} ...")
    info = query_connection(args.target)
    print_info(info)

    if args.query:
        return

    ip = args.ip or ""
    prefix = args.prefix or ""
    gateway = args.gateway or ""
    dns = args.dns or ""
    skip_prompt = False
    remove_mode = bool(args.remove)

    if args.config:
        cfg = load_yaml_config(args.config)
        if cfg.get("remove"):
            remove_mode = True
        ip = str(cfg.get("ip", ip))
        prefix = str(cfg.get("prefix", prefix))
        gateway = str(cfg.get("gateway", gateway))
        dns = str(cfg.get("dns", dns))
        skip_prompt = True

    if remove_mode:
        rm_ip = args.remove or ip
        if not rm_ip:
            print(
                "ERROR: --remove IP or --config with remove: true and ip: is required",
                file=sys.stderr,
            )
            sys.exit(1)
        remove_static_ip(args.target, info, rm_ip, skip_prompt=skip_prompt)
        return

    if not ip:
        print("ERROR: --ip or --config is required when not using --query", file=sys.stderr)
        sys.exit(1)

    if ip.split("/")[0] in [a.split("/")[0] for a in info["dhcp_addresses"] + info["static_addresses"]]:
        print(f"  {ip} is already configured on this device.")
        return

    if not skip_prompt:
        detected_prefix = prefix or parse_prefix(info["dhcp_addresses"][0]) if info["dhcp_addresses"] else "24"
        detected_gw = gateway or info["gateway"]
        detected_dns = dns or (info["dns"][0] if info["dns"] else "")
        print(f"  Will add: {ip}/{detected_prefix}")
        print(f"  Gateway : {detected_gw}")
        print(f"  DNS     : {detected_dns}")
        answer = input("\n  Proceed? [y/N] ").strip().lower()
        if answer != "y":
            print("  Aborted.")
            return

    add_static_ip(args.target, info, ip, prefix, gateway, dns)


if __name__ == "__main__":
    main()
