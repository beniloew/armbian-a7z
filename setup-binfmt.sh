#!/bin/bash
# Register QEMU binfmt handlers for cross-arch builds.
# Required on WSL2 before each build (registrations don't persist across restarts).
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
