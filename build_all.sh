#!/usr/bin/env bash
# ==============================================================================
# build_all.sh - Multi-target RPM builder using Podman
#
# Supported targets:
#   - fedora-44 (x86_64-v2 on x86_64; baseline on aarch64/riscv64)
#   - fedora-45 (x86_64-v2 on x86_64; baseline on aarch64/riscv64)
#   - el-9      (AlmaLinux 9 - x86_64-v2 on x86_64; baseline on aarch64/riscv64)
#   - el-10     (AlmaLinux 10 - x86_64-v3 on x86_64; baseline on aarch64/riscv64)
#
# Output artifacts are placed in:
#   dist/rpms/<target>/
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

ARCH="$(uname -m)"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
NO_CACHE=0
CLEAN_ONLY=0

print_usage() {
    cat << EOF
Usage: $(basename "$0") [options] [target1 target2 ...]

Targets:
  fedora-44   Fedora 44 container
  fedora-45   Fedora 45 container
  el-9        AlmaLinux 9 container (EPEL 9)
  el-10       AlmaLinux 10 container (EPEL 10)
  all         Build all supported targets (default)

Options:
  --no-cache      Re-create builder container images without using local cache
  --clean         Remove build artifacts and cached builder images, then exit
  -h, --help      Show this help message
EOF
}

TARGETS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cache)
            NO_CACHE=1
            shift
            ;;
        --clean)
            CLEAN_ONLY=1
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            TARGETS+=("$1")
            shift
            ;;
    esac
done

if [[ "${CLEAN_ONLY}" -eq 1 ]]; then
    echo "==> Cleaning build artifacts and cached builder images..."
    rm -rf dist/
    for t in fedora-44 fedora-45 el-9 el-10; do
        podman rmi -f "szn-builder-${t}:${ARCH}" 2>/dev/null || true
    done
    echo "==> Clean complete."
    exit 0
fi

if [[ ${#TARGETS[@]} -eq 0 ]] || [[ "${TARGETS[*]}" == *"all"* ]]; then
    TARGETS=("fedora-44" "fedora-45" "el-9" "el-10")
fi

# Check for podman
if ! command -v podman >/dev/null 2>&1; then
    echo "Error: podman is required but not installed." >&2
    exit 1
fi

# Extract version from build.zig.zon
VERSION="$(grep -m1 'version' build.zig.zon | sed -E 's/.*"([^"]+)".*/\1/')"
NAME="szn"

echo "============================================================"
echo " Building ${NAME} v${VERSION} RPM packages"
echo " Host Architecture: ${ARCH}"
echo " Targets:           ${TARGETS[*]}"
echo "============================================================"

# Prepare source tarball
mkdir -p dist/sources
TARBALL="dist/sources/${NAME}-${VERSION}.tar.gz"

echo "==> Generating source tarball: ${TARBALL}"
tar --exclude='.git' \
    --exclude='.hg' \
    --exclude='.zig-cache' \
    --exclude='zig-out' \
    --exclude='dist' \
    --exclude='*.tar.gz' \
    --transform "s,^\.,${NAME}-${VERSION}," \
    -czf "${TARBALL}" .

cp szn.spec dist/sources/
if [[ -f szn.rpmlintrc ]]; then
    cp szn.rpmlintrc dist/sources/
fi

get_base_image() {
    local target="$1"
    case "${target}" in
        fedora-44) echo "docker.io/library/fedora:44" ;;
        fedora-45) echo "docker.io/library/fedora:45" ;;
        el-9)      echo "docker.io/library/almalinux:9" ;;
        el-10)     echo "docker.io/library/almalinux:10" ;;
        *)
            echo "Error: Unknown target '${target}'" >&2
            exit 1
            ;;
    esac
}

get_setup_cmds() {
    local target="$1"
    case "${target}" in
        fedora-44|fedora-45)
            echo "dnf install -y --setopt=install_weak_deps=False zig zig-rpm-macros rpm-build"
            ;;
        el-9|el-10)
            echo "dnf install -y dnf-plugins-core epel-release && crb enable && dnf install -y --setopt=install_weak_deps=False zig zig-rpm-macros rpm-build"
            ;;
    esac
}

ensure_builder_image() {
    local target="$1"
    local builder_tag="szn-builder-${target}:${ARCH}"
    local base_image
    base_image="$(get_base_image "${target}")"
    local setup_cmds
    setup_cmds="$(get_setup_cmds "${target}")"

    if [[ "${NO_CACHE}" -eq 1 ]] || ! podman image exists "${builder_tag}"; then
        echo "==> [${target}] Preparing builder image '${builder_tag}' from ${base_image}..."
        podman run --name "szn-prep-${target}" "${base_image}" bash -c "${setup_cmds}"
        podman commit "szn-prep-${target}" "${builder_tag}" >/dev/null
        podman rm -f "szn-prep-${target}" >/dev/null
        echo "==> [${target}] Builder image cached: ${builder_tag}"
    else
        echo "==> [${target}] Using cached builder image: ${builder_tag}"
    fi
}

FAILED_TARGETS=()

for target in "${TARGETS[@]}"; do
    echo ""
    echo "------------------------------------------------------------"
    echo " Building for target: ${target} (${ARCH})"
    echo "------------------------------------------------------------"

    if [[ "${ARCH}" == "riscv64" ]] && [[ "${target}" =~ ^el- ]]; then
        echo "Notice: Enterprise Linux (${target}) does not provide official riscv64 container images; skipping."
        continue
    fi

    TARGET_OUT_DIR="dist/rpms/${target}"
    mkdir -p "${TARGET_OUT_DIR}"

    if ! ensure_builder_image "${target}"; then
        echo "Error: Failed to prepare builder image for ${target}" >&2
        FAILED_TARGETS+=("${target}")
        continue
    fi

    BUILDER_TAG="szn-builder-${target}:${ARCH}"

    echo "==> [${target}] Running rpmbuild..."
    if podman run --rm \
        -v "$(pwd)/dist/sources:/sources:z" \
        -v "$(pwd)/${TARGET_OUT_DIR}:/output:z" \
        -e HOST_UID="${HOST_UID}" \
        -e HOST_GID="${HOST_GID}" \
        "${BUILDER_TAG}" bash -c '
            set -euo pipefail
            mkdir -p /tmp/rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
            cp /sources/* /tmp/rpmbuild/SOURCES/
            cp /sources/szn.spec /tmp/rpmbuild/SPECS/
            cd /tmp/rpmbuild/SPECS
            rpmbuild --define "_topdir /tmp/rpmbuild" -ba szn.spec
            cp -r /tmp/rpmbuild/RPMS/*/* /output/
            cp -r /tmp/rpmbuild/SRPMS/* /output/
            chown -R "${HOST_UID}:${HOST_GID}" /output
        '; then
        echo "==> [${target}] Build succeeded!"
    else
        echo "Error: [${target}] Build failed!" >&2
        FAILED_TARGETS+=("${target}")
    fi
done

echo ""
echo "============================================================"
echo " Build Summary"
echo "============================================================"
for target in "${TARGETS[@]}"; do
    TARGET_OUT_DIR="dist/rpms/${target}"
    if [[ -d "${TARGET_OUT_DIR}" ]] && compgen -G "${TARGET_OUT_DIR}/*.rpm" >/dev/null; then
        echo "[SUCCESS] ${target}:"
        ls -lh "${TARGET_OUT_DIR}"/*.rpm | awk '{printf "  - %-45s (%s)\n", $9, $5}'
    else
        echo "[FAILED]  ${target}"
    fi
done

if [[ ${#FAILED_TARGETS[@]} -ne 0 ]]; then
    echo ""
    echo "Failed targets: ${FAILED_TARGETS[*]}" >&2
    exit 1
fi

echo ""
echo "All RPM packages built successfully in dist/rpms/!"
