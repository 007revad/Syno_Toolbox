#!/bin/bash
#----------------------------------------------------------
# Syno_Toolbox module: pkg_depends.sh
# Lists packages that depend on other packages or services.
#
# Always prints something and exits 0 - api.cgi's run action treats
# empty output as a failure.
#----------------------------------------------------------

pkg_name() {
    /usr/syno/bin/synogetkeyvalue "/var/packages/$1/INFO" displayname
}

echo_needed=""
found_pkgs=0
found_services=0
for p in /var/packages/*; do
    file="$p/INFO"
    if grep -qE 'install_dep_packages=".+"' "$file"; then
        found_pkgs=$((found_pkgs +1))
        dep_packages=()
        displayname="$(pkg_name "${p##*/}")"

        # Show package displayname
        if [[ "$echo_needed" == yes ]]; then
            echo -e "\n${displayname}:"
        else
            # Don't add newline before first package
            echo "${displayname}:"
            echo_needed="yes"
        fi

        dep_pkgs="$(/usr/syno/bin/synogetkeyvalue "$file" install_dep_packages)"
        dep_pkgs="${dep_pkgs//:/ }"
        read -r -a dep_packages <<< "$dep_pkgs"

        for dep_p in "${dep_packages[@]}"; do
            # Add space before and after >=, <=, >, < or =
            if [[ "$dep_p" =~ "<=" ]]; then
                b="${dep_p//<=/ <= }"
            elif [[ "$dep_p" =~ ">=" ]]; then
                b="${dep_p//>=/ >= }"
            elif [[ "$dep_p" =~ "<" ]]; then
                b="${dep_p//</ < }"
            elif [[ "$dep_p" =~ ">" ]]; then
                b="${dep_p//>/ > }"
            elif [[ "$dep_p" =~ "=" ]]; then
                b="${dep_p//=/ = }"
            else
                b=""
            fi

            # Split into pkgname and deps
            if [[ -n "$b" ]]; then
                a="${b%% *}"  # part before first space
                b="${b#* }"   # part after first space
            else
                a="$dep_p"
            fi

            # Get displayname for $a
            a="$(pkg_name "$a")"

            # Show result
            echo "  $a $b"
        done
    fi
done


if [[ ! "$found_pkgs" -gt 0 ]]; then
    echo -e "\nNo dependant packages found."
fi
# install_dep_services are always built-in Synology services
#if [[ ! "$found_services" -gt 0 ]]; then
#    echo -e "\nNo dependant services found."
#fi

exit 0


#for p in /var/packages/*; do if grep -qE 'install_dep_packages=".+"' "$p/INFO"; then echo -e "\n$(basename "$p")" && grep 'install_dep_packages' "$p/INFO"; fi; done
#for p in /var/packages/*; do if grep -qE 'install_dep_services=".+"' "$p/INFO"; then echo -e "\n$(basename "$p")" && grep 'install_dep_services' "$p/INFO"; fi; done

