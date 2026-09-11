#!/usr/bin/env bash
# shellcheck disable=SC2034

scriptver="v1.0.0-toolbox"
script=hardware_info

nas_revision="$(cat /proc/sys/kernel/syno_hw_revision)"
if [[ $nas_revision ]]; then nas_revision=" $nas_revision"; fi

# Get NAS model
nas_model=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/synoinfo.conf upnpmodelname 2>/dev/null)
# Fallback for systems where upnpmodelname is unavailable
if [[ -z "$nas_model" && -f /proc/sys/kernel/syno_hw_version ]]; then
    nas_model=$(cat /proc/sys/kernel/syno_hw_version 2>/dev/null || echo "")
    # Check for dodgy characters after model number
    if [[ ${nas_model,,} =~ 'pv10-j'$ ]]; then  # GitHub issue #10
        nas_model=${nas_model%??????}+          # replace last 6 chars with +
    elif [[ ${nas_model} =~ '-j'$ ]]; then      # GitHub issue #2
        nas_model=${nas_model%??}               # remove last 2 chars
    fi
fi
if [[ -z "$nas_model" ]]; then
    nas_model="Unknown_model"
fi

nas_revision=$(cat /proc/sys/kernel/syno_hw_revision)
if [[ -n $nas_revision ]]; then
    show_revision="  revision $nas_revision"
fi

nas_cpu="$(cat /proc/cpuinfo | grep 'model name' | tail -1)"
nas_cpu="${nas_cpu##*: }"

nas_arch=$(uname -m)

nas_platform=$(uname -a)
nas_platform="${nas_platform##*synology_}"
nas_platform="${nas_platform%%_*}"

nas_kernel=$(uname -r)
nas_last_kernel_patch=$(uname -v)

nas_serial=$(cat /proc/sys/kernel/syno_serial)

nas_hostname=$(uname -n)

echo "Model:    ${nas_model}$show_revision"
echo "CPU:      $nas_cpu"
echo "Platform: $nas_platform"
echo "Arch:     $nas_arch"
echo "Kernel:   $nas_kernel  ${nas_last_kernel_patch}"
echo "Serial:   $nas_serial"
echo "Hostname: $nas_hostname"

