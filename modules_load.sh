#! /usr/bin/env bash

OPERATION="insmod"
SUFFIX=".ko"
MESSAGE="Loading"

# installed modules location for current kernel
KVER=$(uname -r)
EXTRA_DIR="/lib/modules/${KVER}/extra"

mapfile -t MODULES_TMP < modules.order
MODULES=("${MODULES_TMP[@]}")

LOADED_MODULES=$(lsmod)

if [[ $1 == "unload" ]]; then
    OPERATION="rmmod -f"
    SUFFIX=""
    MESSAGE="Unloading"

    # array reversing for rmmod
    len=${#MODULES[@]}
    for ((i = 0 ; i < $len ; i++)); do
        MODULES[$i]=${MODULES_TMP[(( $len - $i - 1 ))]}
    done

    # attempt to remove conflicting modules first
    [[ $LOADED_MODULES =~ "xpad" ]] && rmmod -f xpad
    [[ $LOADED_MODULES =~ "mt76x2u" ]] && rmmod -f mt76x2u
fi

# make sure ff-memless is loaded as it exports some needed symbols
if [[ $1 != "unload" && ! "$LOADED_MODULES" =~ "ff-memless" ]]; then
    modprobe ff-memless
fi

for module in "${MODULES[@]}"; do
    # strip .o and keep base module name
    base="${module%.o}"

    # check for installed .ko or .ko.xz in /lib/modules/$(uname -r)/extra
    installed_plain="${EXTRA_DIR}/${base}.ko"
    installed_xz="${installed_plain}.xz"

    if [[ $1 == "unload" ]]; then
        # skip if module not loaded
        [[ ! "$LOADED_MODULES" =~ "$base" ]] && continue

        if [[ -f "$installed_plain" || -f "$installed_xz" ]]; then
            echo "${MESSAGE} installed module ${base} (using modprobe -r)"
            modprobe -r "$base"
        else
            echo "${MESSAGE} ${base} (using rmmod -f)"
            rmmod -f "$base"
        fi
    else
        # load path: prefer modprobe for installed modules (handles .ko.xz),
        # otherwise fall back to insmod local .ko
        if [[ -f "$installed_plain" || -f "$installed_xz" ]]; then
            echo "${MESSAGE} installed module ${base} (using modprobe)"
            if ! modprobe "$base"; then
                # fallback: if modprobe fails try to insmod the installed plain .ko
                if [[ -f "$installed_plain" ]]; then
                    echo "modprobe failed, trying insmod ${installed_plain}"
                    insmod "$installed_plain"
                else
                    echo "modprobe failed and no plain .ko to insmod for ${base}"
                fi
            fi
        else
            # local module in this tree
            localpath="${base}${SUFFIX}"
            echo "${MESSAGE} local module ${localpath} (using insmod)"
            $OPERATION "$localpath"
        fi
    fi
done
