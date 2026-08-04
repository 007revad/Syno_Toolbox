#!/usr/bin/env bash
# https://github.com/007revad/Restore_RS3621_Fan_Speed
#
# Restore DSM 7.3.2 RS3621XS+ and RS3621RPxs fan speeds to DSM 7.3.1 speeds
#
# Edit /usr/syno/etc.defaults/scemd.xml
#
# Change first pwm_duty_low to 50 only if it is currently 100
#<pwm_config name="pwm2" sensor_type="allinput" high_freq="yes" pwm_duty_low="100" pwm_duty_high="220"></pwm_config>
#
# Change second pwm_duty_low to 100 only if it is currently 120
#<pwm_config name="pwm2" sensor_type="allinput" high_freq="yes" pwm_duty_low="120" pwm_duty_high="220"></pwm_config>

# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "ERROR This script must be run as sudo or root"
    exit 1
fi

# Check DSM version needs script
dsm_version=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION productversion)
buildnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildnumber)
if [[ $buildnumber -lt "86009" ]]; then
    echo "ERROR Script not needed for DSM ${dsm_version}-$buildnumber"
    exit 1
fi

# Check correct Synology model
supported_models=("RS3621xs+" "RS3621RPxs")
model=$(cat /proc/sys/kernel/syno_hw_version)
if [[ ! ${supported_models[*]} =~ $model ]]; then
    echo -e "ERROR Script not needed for $model"
    exit 1
fi

# Backup scemd.xml if no backup exists
scemd_file="/usr/syno/etc.defaults/scemd.xml"

if [[ ! -f "${scemd_file}.bak" ]]; then
    backup_file="${scemd_file}.bak"
    if cp -p "$scemd_file" "$backup_file"; then
        echo -e "Backed up scemd.xml to: ${backup_file}\n"
    else
        echo -e "ERROR Failed to backup $scemd_file \n to: $backup_file\n"
    fi
else
    echo -e "Backup of scemd.xml already exists\n"
fi


edit_scemdxml(){ 
    # Parse the XML file and modify pwm_config elements ONLY if they have expected values:
    # First pwm_config: change pwm_duty_low="100" to "50" (only if currently "100")
    # Second pwm_config: change pwm_duty_low="120" to "100" (only if currently "120")

    # Execute Python script using HERE document
    python3 << 'PYTHON_EOF'
import xml.etree.ElementTree as ET
import sys
import os

def edit_pwm_config(input_file, output_file):
    try:
        # Parse the XML file
        tree = ET.parse(input_file)
        root = tree.getroot()
        
        # Find all pwm_config elements
        pwm_configs = root.findall('.//pwm_config')
        
        if len(pwm_configs) < 2:
            print(f"Error: Expected at least 2 <pwm_config> elements, found {len(pwm_configs)}")
            return False
        
        modified = False
        
        # Modify the first pwm_config element (only if pwm_duty_low="100")
        first_pwm = pwm_configs[0]
        old_value_1 = first_pwm.get('pwm_duty_low')
        print(f"[First <pwm_config> element]")
        print(f"Current pwm_duty_low: {old_value_1}")
        
        if old_value_1 == '100':
            first_pwm.set('pwm_duty_low', '50')
            new_value_1 = first_pwm.get('pwm_duty_low')
            print(f"Updated pwm_duty_low: {new_value_1}")
            modified = True
        else:
            print(f"Skipped - expected '100' but found '{old_value_1}'")
        
        # Modify the second pwm_config element (only if pwm_duty_low="120")
        second_pwm = pwm_configs[1]
        old_value_2 = second_pwm.get('pwm_duty_low')
        print(f"\n[Second <pwm_config> element]")
        print(f"Current pwm_duty_low: {old_value_2}")
        
        if old_value_2 == '120':
            second_pwm.set('pwm_duty_low', '100')
            new_value_2 = second_pwm.get('pwm_duty_low')
            print(f"Updated pwm_duty_low: {new_value_2}")
            modified = True
        else:
            print(f"Skipped - expected '120' but found '{old_value_2}'")
        
        if modified:
            # Write the modified XML back to file
            tree.write(output_file, encoding='UTF-8', xml_declaration=True)
            print(f"\nSuccessfully saved modified XML to: {output_file}")
            return True
        else:
            print(f"\nNo modifications made - default values not found")
            return False
        
    except ET.ParseError as e:
        print(f"Error parsing XML: {e}")
        return False
    except Exception as e:
        print(f"Error: {e}")
        return False

# Call the function - note the scemd_file variable from bash will be substituted here
scemd_file = os.environ.get('scemd_file', '/usr/syno/etc.defaults/scemd.xml')
if edit_pwm_config(scemd_file, scemd_file):
    print("\nDone!")
else:
    print("\nFailed to modify the file")
PYTHON_EOF
}

# Export the variable so it's available to the Python subprocess
export scemd_file
edit_scemdxml
