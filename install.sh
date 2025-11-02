#! /usr/bin/env bash

set -eu

SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SIGN_HELPER="${SCRIPT_ROOT}/scripts/sign-modules.sh"

SIGN_KEY=${SIGN_KEY:-}
SIGN_CERT=${SIGN_CERT:-}
SIGN_HASH=${SIGN_HASH:-sha256}
SIGN_FILE_OVERRIDE=${SIGN_FILE:-}

DETECTED_SIGN_KEY=""
DETECTED_SIGN_CERT=""

is_secure_boot_enabled() {
    if [ ! -d /sys/firmware/efi ]; then
        return 1
    fi

    if command -v mokutil >/dev/null 2>&1; then
        local sb_state
        sb_state=$(mokutil --sb-state 2>/dev/null || true)
        if printf '%s\n' "$sb_state" | grep -qi 'SecureBoot\W*enabled'; then
            return 0
        fi
        if printf '%s\n' "$sb_state" | grep -qi 'SecureBoot\W*disabled'; then
            return 1
        fi
    fi

    local result=1
    local nullglob_state
    nullglob_state=$(shopt -p nullglob || true)
    shopt -s nullglob

    local path
    for path in /sys/firmware/efi/vars/SecureBoot-*; do
        local data_file="$path/data"
        if [ -r "$data_file" ]; then
            local value
            value=$(od -An -t u1 -N1 "$data_file" 2>/dev/null | tr -d ' ')
            if [ "$value" = 1 ]; then
                result=0
                break
            elif [ "$value" = 0 ]; then
                result=1
                break
            fi
        fi
    done

    if [ "$result" -eq 1 ]; then
        for path in /sys/firmware/efi/efivars/SecureBoot-*; do
            if [ -r "$path" ]; then
                local value
                value=$(od -An -t u1 -N1 "$path" 2>/dev/null | tr -d ' ')
                if [ "$value" = 1 ]; then
                    result=0
                    break
                elif [ "$value" = 0 ]; then
                    result=1
                    break
                fi
            fi
        done
    fi

    eval "$nullglob_state"
    return "$result"
}

is_auto_placeholder() {
    case "$1" in
        AUTO_FEDORA|fedora)
            return 0
            ;;
    esac

    return 1
}

if [ "$(id -u)" -ne 0 ]; then
    echo 'This script must be run as root!' >&2
    exit 1
fi

if ! [ -x "$(command -v dkms)" ]; then
    echo 'This script requires DKMS!' >&2
    exit 1
fi

if [ -f /usr/local/bin/xow ]; then
    echo 'Please uninstall xow!' >&2
    exit 1
fi

if [ -n "${SUDO_USER:-}" ]; then
    # Run as normal user to prevent "unsafe repository" error
    version=$(sudo -u "$SUDO_USER" git describe --tags 2> /dev/null || echo unknown)
else
    version=unknown
fi

# remove "v" prefix
version=${version##v}

secure_boot_active=0
if is_secure_boot_enabled; then
    secure_boot_active=1
fi

source="/usr/src/xone-$version"
log="/var/lib/dkms/xone/$version/build/make.log"

if [ -n "$(dkms status xone)" ]; then
    echo -e 'Driver is already installed, uninstalling...\n'
    ./uninstall.sh --no-firmware
fi

if [ "$secure_boot_active" -eq 1 ]; then
    echo 'Secure Boot is enabled; signed modules are required.'

    if [ -z "$SIGN_KEY" ] || [ -z "$SIGN_CERT" ]; then
        echo 'SIGN_KEY and SIGN_CERT not set, attempting auto-detection...'
        SIGN_KEY="AUTO_FEDORA"
        SIGN_CERT="AUTO_FEDORA"
    elif ! is_auto_placeholder "$SIGN_KEY"; then
        if [ ! -r "$SIGN_KEY" ]; then
            echo "Secure Boot is enabled but SIGN_KEY '$SIGN_KEY' is not readable." >&2
            exit 1
        fi

        if [ ! -r "$SIGN_CERT" ]; then
            echo "Secure Boot is enabled but SIGN_CERT '$SIGN_CERT' is not readable." >&2
            exit 1
        fi
    fi

    # Resolve AUTO_FEDORA to actual paths before DKMS build
    if is_auto_placeholder "$SIGN_KEY"; then
        AKMODS_CERT_DIR="/etc/pki/akmods/certs"
        AKMODS_PRIV_DIR="/etc/pki/akmods/private"

        if [ -d "$AKMODS_CERT_DIR" ] && [ -d "$AKMODS_PRIV_DIR" ]; then
            DETECTED_SIGN_CERT="$AKMODS_CERT_DIR/public_key.der"
            DETECTED_SIGN_KEY="$AKMODS_PRIV_DIR/private_key.priv"

            if [ -f "$DETECTED_SIGN_KEY" ] && [ -f "$DETECTED_SIGN_CERT" ]; then
                echo "Auto-detected Fedora akmods key: $DETECTED_SIGN_KEY and cert: $DETECTED_SIGN_CERT"
                SIGN_KEY="$DETECTED_SIGN_KEY"
                SIGN_CERT="$DETECTED_SIGN_CERT"
            else
                echo "Warning: akmods keys not found at expected paths" >&2
            fi
        fi
    fi
fi

echo "Installing xone $version..."
cp -r . "$source"
find "$source" -type f \( -name dkms.conf -o -name '*.c' \) -exec sed -i "s/#VERSION#/$version/" {} +

# The MAKE line in dkms.conf is required for kernels built using clang.
# Add it if the kernel is built using gcc - i.e. "clang" is in the kernel
# version string.
if [ -n "$(cat /proc/version | grep clang)" ]; then
    echo 'MAKE[0]="make V=1 LLVM=1 -C ${kernel_source_dir}'\
        'M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build"'\
        >> "$source/dkms.conf"
fi

if [ "${1:-}" == --debug ]; then
    echo 'ccflags-y += -DDEBUG' >> "$source/Kbuild"
fi

sign_modules() {
    local version="$1"
    local dkms_tree="/var/lib/dkms/xone/$version"
    local module_dirs=()

    if [ -d "$dkms_tree" ]; then
        mapfile -t module_dirs < <(find "$dkms_tree" -type d -name module -print)
    fi

    # Also check for build directory (where modules are before/during installation)
    local build_dir="$dkms_tree/build"
    if [ -d "$build_dir" ]; then
        local ko_files
        ko_files=$(find "$build_dir" -maxdepth 1 -name '*.ko' 2>/dev/null | head -1 || true)
        if [ -n "$ko_files" ]; then
            module_dirs+=("$build_dir")
        fi
    fi

    if [ "${#module_dirs[@]}" -eq 0 ]; then
        echo "Warning: no DKMS module directories found for signing" >&2
        return
    fi

    declare -A signed_destinations=()
    for module_dir in "${module_dirs[@]}"; do
        # Determine kernel release based on directory structure
        local kernel_release
        if [[ "$module_dir" == */build ]]; then
            # For build directory, use current kernel
            kernel_release=$(uname -r)
        else
            local kernel_arch_dir=$(dirname "$module_dir")
            local kernel_root_dir=$(dirname "$kernel_arch_dir")
            kernel_release=$(basename "$kernel_root_dir")
        fi

        local sign_file
        if [ -n "$SIGN_FILE_OVERRIDE" ]; then
            sign_file="$SIGN_FILE_OVERRIDE"
        else
            sign_file="/lib/modules/$kernel_release/build/scripts/sign-file"
        fi

        if [ ! -x "$sign_file" ]; then
            echo "Warning: sign-file helper '$sign_file' not available for kernel $kernel_release" >&2
            continue
        fi

        "$SIGN_HELPER" "$module_dir" "$sign_file" "$SIGN_HASH" "$SIGN_KEY" "$SIGN_CERT"

        # Also sign installed modules in extra directory (where DKMS installs them)
        local installed_dir="/lib/modules/$kernel_release/extra"
        if [ -d "$installed_dir" ] && [ -z "${signed_destinations[$installed_dir]:-}" ]; then
            "$SIGN_HELPER" "$installed_dir" "$sign_file" "$SIGN_HASH" "$SIGN_KEY" "$SIGN_CERT"
            signed_destinations[$installed_dir]=1
        fi

        # Check updates/dkms directory as well
        local updates_dir="/lib/modules/$kernel_release/updates/dkms"
        if [ -d "$updates_dir" ] && [ -z "${signed_destinations[$updates_dir]:-}" ]; then
            "$SIGN_HELPER" "$updates_dir" "$sign_file" "$SIGN_HASH" "$SIGN_KEY" "$SIGN_CERT"
            signed_destinations[$updates_dir]=1
        fi
    done
}

# Pass signing keys to DKMS via configuration override
if [ -n "$SIGN_KEY" ] && [ -n "$SIGN_CERT" ] && [ -f "$SIGN_KEY" ] && [ -f "$SIGN_CERT" ]; then
    # Create temporary DKMS config to override signing keys
    TEMP_DKMS_CONF=$(mktemp)
    cat > "$TEMP_DKMS_CONF" <<EOF
mok_signing_key="$SIGN_KEY"
mok_certificate="$SIGN_CERT"
sign_file="/lib/modules/\$kernelver/build/scripts/sign-file"
EOF
    export dkms_directive="--directive='mok_signing_key=$SIGN_KEY' --directive='mok_certificate=$SIGN_CERT'"
fi

if [ -n "$TEMP_DKMS_CONF" ] && [ -f "$TEMP_DKMS_CONF" ]; then
    # Use directive to override DKMS signing configuration
    dkms install -m xone -v "$version" --force --directive="mok_signing_key=$SIGN_KEY" --directive="mok_certificate=$SIGN_CERT"
    install_result=$?
    rm -f "$TEMP_DKMS_CONF"
else
    dkms install -m xone -v "$version" --force
    install_result=$?
fi

if [ "$install_result" -eq 0 ]; then
    # The blacklist should be placed in /usr/local/lib/modprobe.d for kmod 29+
    install -D -m 644 install/modprobe.conf /etc/modprobe.d/xone-blacklist.conf

    # Avoid conflicts between xpad and xone
    if lsmod | grep -q '^xpad'; then
        modprobe -r xpad
    fi

    # Avoid conflicts between mt76x2u and xone
    if lsmod | grep -q '^mt76x2u'; then
        modprobe -r mt76x2u
    fi

    if [ -n "$SIGN_KEY" ] && [ -n "$SIGN_CERT" ]; then
        if [ ! -x "$SIGN_HELPER" ] && [ "$secure_boot_active" -eq 1 ]; then
            echo "Error: Secure boot is enabled and module signing helper '$SIGN_HELPER' not found" >&2
            exit 1
        else
            sign_modules "$version"
        fi
    elif [ -n "$SIGN_KEY" ] || [ -n "$SIGN_CERT" ]; then
        echo 'Warning: both SIGN_KEY and SIGN_CERT must be set to enable module signing' >&2
    fi

    # Post-install test: verify modules can be loaded
    echo -e "\nRunning post-install test..."
    test_failed=0

    # Ensure ff-memless is loaded (required dependency)
    if ! lsmod | grep -q '^ff_memless'; then
        if ! modprobe ff-memless 2>/dev/null; then
            echo "Warning: failed to load ff-memless module" >&2
            test_failed=1
        fi
    fi

    # Try loading the core xone modules
    kernel_release=$(uname -r)
    module_paths=(
        "/lib/modules/$kernel_release/updates/dkms"
        "/lib/modules/$kernel_release/extra"
    )

    modules_loaded=()
    for module_name in xone_gip xone_wired xone_dongle; do
        module_found=0
        for module_path in "${module_paths[@]}"; do
            if [ -f "$module_path/${module_name}.ko" ] || [ -f "$module_path/${module_name}.ko.xz" ]; then
                module_found=1
                if modprobe "$module_name" 2>/dev/null; then
                    echo "  ✓ Successfully loaded $module_name"
                    modules_loaded+=("$module_name")
                else
                    echo "  ✗ Failed to load $module_name" >&2
                    test_failed=1
                fi
                break
            fi
        done

        if [ "$module_found" -eq 0 ]; then
            echo "  ✗ Module $module_name not found in expected locations" >&2
            test_failed=1
        fi
    done

    # Unload test modules
    for module_name in "${modules_loaded[@]}"; do
        modprobe -r "$module_name" 2>/dev/null || true
    done

    if [ "$test_failed" -eq 0 ]; then
        echo -e "\n✓ Post-install test passed: modules can be loaded without reboot\n"
    else
        echo -e "\n⚠ Post-install test completed with warnings"
        echo "  Some modules may require a reboot or additional configuration\n"
    fi
else
    if [ -r "$log" ]; then
        cat "$log" >&2
    fi

    exit 1
fi

echo -e "xone installation finished\n"
