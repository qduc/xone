#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: sign-modules.sh <module_dir> <sign_file> <hash_algo> <private_key> <x509_cert>

Sign every .ko module in <module_dir> using the kernel's sign-file helper.
EOF
}

if [ "$#" -ne 5 ]; then
    usage >&2
    exit 1
fi

module_dir=$1
sign_file=$2
hash_algo=$3
private_key=$4
public_cert=$5

# Allow overriding akmods dir for testing; default to Fedora location
AKMODS_DIR=${AKMODS_DIR:-/etc/pki/akmods}

# If caller asked for 'fedora' or the provided key/cert are missing, try auto-detect
try_use_fedora=0
if [ "$private_key" = "fedora" ] || [ "$private_key" = "AUTO_FEDORA" ]; then
    try_use_fedora=1
fi
if [ "$try_use_fedora" -eq 0 ]; then
    if [ ! -f "$private_key" ] || [ ! -f "$public_cert" ]; then
        try_use_fedora=1
    fi
fi

tmp_converted_cert=""
if [ "$try_use_fedora" -eq 1 ] && [ -d "$AKMODS_DIR" ]; then
    cert_dir="$AKMODS_DIR/certs"
    priv_dir="$AKMODS_DIR/private"
    if [ -d "$cert_dir" ] && [ -d "$priv_dir" ]; then
        # Prefer matching public cert (der or pem)
        # found_cert=$(ls -1 "$cert_dir"/*.der 2>/dev/null | head -n1 || true)
        found_cert="/etc/pki/akmods/certs/public_key.der"
        if [ -z "$found_cert" ]; then
            found_cert=$(ls -1 "$cert_dir"/*.pem 2>/dev/null | head -n1 || true)
        fi

        # Pick first private key available
        # found_key=$(ls -1 "$priv_dir"/* 2>/dev/null | head -n1 || true)
        found_key="/etc/pki/akmods/private/private_key.priv"

        if [ -n "$found_cert" ] && [ -n "$found_key" ]; then
            echo "Auto-detected Fedora akmods key: $found_key and cert: $found_cert" >&2
            private_key="$found_key"

            # Convert DER cert to PEM if needed
            if printf '%s' "$found_cert" | grep -q '\.der$'; then
                tmp_converted_cert=$(mktemp)
                if ! openssl x509 -in "$found_cert" -inform DER -out "$tmp_converted_cert" -outform PEM 2>/dev/null; then
                    rm -f "$tmp_converted_cert"
                    tmp_converted_cert=""
                else
                    public_cert="$tmp_converted_cert"
                fi
            else
                public_cert="$found_cert"
            fi
        fi
    fi
fi

if [ ! -f "$private_key" ]; then
    echo "Private key '$private_key' not found" >&2
    [ -n "$tmp_converted_cert" ] && rm -f "$tmp_converted_cert"
    exit 1
fi

if [ ! -f "$public_cert" ]; then
    echo "X.509 certificate '$public_cert' not found" >&2
    [ -n "$tmp_converted_cert" ] && rm -f "$tmp_converted_cert"
    exit 1
fi

if [ ! -d "$module_dir" ]; then
    echo "Module directory '$module_dir' does not exist" >&2
    exit 1
fi

if [ ! -x "$sign_file" ]; then
    echo "sign-file helper '$sign_file' is not executable" >&2
    exit 1
fi

if [ ! -f "$private_key" ]; then
    echo "Private key '$private_key' not found" >&2
    exit 1
fi

if [ ! -f "$public_cert" ]; then
    echo "X.509 certificate '$public_cert' not found" >&2
    exit 1
fi

mapfile -t modules < <(find "$module_dir" -maxdepth 1 \( -type f -o -type l \) \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) -print)

if [ "${#modules[@]}" -eq 0 ]; then
    echo "No kernel modules found in '$module_dir'" >&2
    exit 0
fi

declare -A seen_targets=()

for module in "${modules[@]}"; do
    target=$(readlink -f "$module")
    if [ -z "$target" ]; then
        target="$module"
    fi

    if [ ! -f "$target" ]; then
        echo "Skipping '$module' because the resolved target '$target' does not exist" >&2
        continue
    fi

    if [ -n "${seen_targets[$target]:-}" ]; then
        echo "Skipping '${module##*/}' (already signed via '$target')" >&2
        continue
    fi

    # Handle compressed modules
    needs_cleanup=0
    uncompressed_target="$target"

    if [[ "$target" == *.ko.xz ]]; then
        echo "Decompressing ${module##*/} for signing..." >&2
        uncompressed_target="${target%.xz}"
        xz -dc "$target" > "$uncompressed_target"
        needs_cleanup=1
    elif [[ "$target" == *.ko.zst ]]; then
        echo "Decompressing ${module##*/} for signing..." >&2
        uncompressed_target="${target%.zst}"
        zstd -dc "$target" > "$uncompressed_target"
        needs_cleanup=1
    fi

    echo "Signing ${module##*/}" >&2
    "$sign_file" "$hash_algo" "$private_key" "$public_cert" "$uncompressed_target"

    # Recompress if needed
    if [ "$needs_cleanup" -eq 1 ]; then
        if [[ "$target" == *.ko.xz ]]; then
            echo "Recompressing ${module##*/} with kernel-compatible settings..." >&2
            # Use CRC32 checksum and a 1MiB LZMA2 dictionary so the kernel's
            # XZ embedded decompressor can handle the module (avoids CRC64
            # and large dictionaries which the kernel doesn't support).
            xz --check=crc32 --lzma2=dict=1MiB -f "$uncompressed_target"
        elif [[ "$target" == *.ko.zst ]]; then
            echo "Recompressing ${module##*/}..." >&2
            zstd -f -o "$target" "$uncompressed_target"
            rm -f "$uncompressed_target"
        fi
    fi

    seen_targets[$target]=1
done

[ -n "$tmp_converted_cert" ] && rm -f "$tmp_converted_cert"

exit 0
