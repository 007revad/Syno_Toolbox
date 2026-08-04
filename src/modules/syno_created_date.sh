#!/usr/bin/env bash
#
# v1.1.1
# - Added code to decode expansion unit serial numbers.
# - Changed to be 11 seconds faster for models without syno_slot_mapping command.
# - Bug fix for old models with serial numbers starting with a letter.
# - Bug fix for when language is set to "Browser default".

# /etc/synoinfo.conf
# codepage="enu"
# language="def"
# maillang="enu"
# supplang="enu,cht,chs,krn,tha,ger,fre,ita,spn,jpn,dan,nor,sve,nld,rus,plk,ptb,ptg,hun,trk,csy"

scriptver="v1.1.2"
script=Synology_created_date
repo="007revad/Synology_created_date"
#scriptname=syno_created_date

# Show script version
echo -e "$script $scriptver\ngithub.com/$repo\n"
#echo -e "$script $scriptver\n"

nas_revision="$(cat /proc/sys/kernel/syno_hw_revision)"
if [[ $nas_revision ]]; then nas_revision=" $nas_revision"; fi

nas_model=$(cat /proc/sys/kernel/syno_hw_version)

nas_serial=$(cat /proc/sys/kernel/syno_serial)

lang=$(synogetkeyvalue "/etc/synoinfo.conf" language)
if [[ $lang == "def" ]]; then  
    # Display language set to "Browser default" so we use "Notification language"
    lang=$(synogetkeyvalue "/etc/synoinfo.conf" maillang)
fi

decode(){ 
    case "$1" in
        0) n=0;;
        1) n=1;;
        2) n=2;;
        3) n=3;;
        4) n=4;;
        5) n=5;;
        6) n=6;;
        7) n=7;;
        8) n=8;;
        9) n=9;;
        A) n=10;;
        B) n=11;;
        C) n=12;;
        D) n=13;;
        E) n=14;;
        F) n=15;;
        G) n=16;;
        H) n=17;;
        I) n=18;;
        J) n=19;;
        *) echo "Invalid arg '$1'";;
    esac
}

get_date(){
    local serial="$1"
    if [[ $2 == "old" ]]; then
        # Old format serial number: B5J6N00567 or 72DBN00554
        decode "${serial:0:1}"  # Convert 1st character
        if [[ ${#n} = 1 ]]; then
            year="0$n"
        else
            year="$n"
        fi
        decode "${serial:1:1}"  # Convert 2nd character
    else
        # Current format serial number: 163xxxxxxxxxx or 20Cxxxxxxxxxx
        year="${serial:0:2}"    # First 2 characters
        decode "${serial:2:1}"  # Convert 3rd character
    fi
    if [[ $lang ]]; then
        month=$(synogetkeyvalue "/usr/syno/synoman/webman/texts/${lang}/strings" "mon_$n")
    elif [[ ${#n} = 1 ]]; then
        month="0$n"
    else
        month="$n"
    fi
    build_date="20$year $month"
}

convert_serial(){
    local serial="$1"
    if [[ ${serial:0:1} =~ [0-9] ]] && [[ ${#serial} -gt 10 ]]; then
        # Is current serial number format
        get_date "$serial" current
    elif [[ ${serial:0:1} =~ [A-V] ]]; then
        # Is old serial number format
        get_date "$serial" old
    elif [[ ${serial:0:1} =~ [0-9] ]] && [[ ${#serial} -eq 10 ]]; then
        # Is original serial number format
        get_date "$serial" old
    else
        echo "Unknown serial number format: $serial"
        #exit
    fi 
}


# Show manufactured date for NAS
convert_serial "$nas_serial"
if [[ $lang ]]; then
    made=$(synogetkeyvalue "/usr/syno/synoman/webman/texts/${lang}/strings" version_time)
    echo -e "${nas_model}$nas_revision $nas_serial ${made}: $build_date"
else
    echo -e "${nas_model}$nas_revision $nas_serial Date Created: $build_date"
fi


#------------------------------------------------------------------------------
# Expansion units

eunit_lang(){ 
    case "$1" in
        chs)
            question="请输入 $eunit 序列号的前 3 个字符";;
        cht)
            question="請輸入 $eunit 序號的前 3 個字元";;
        csy)
            question="Zadejte první 3 znaky sériového čísla $eunit";;
        dan)
            question="Indtast de første 3 tegn i $eunit serienummeret";;
        enu)
            question="Enter the first 3 characters of $eunit serial number";;
        fre)
            question="Saisissez les 3 premiers caractères du numéro de série $eunit";;
        ger)
            question="Geben Sie die ersten 3 Zeichen der Seriennummer $eunit ein";;
        hun)
            question="Írja be a $eunit sorozatszámának első 3 karakterét";;
        ita)
            question="Inserisci i primi 3 caratteri del numero di serie $eunit";;
        jpn)
            question="$eunitシリアル番号の最初の3文字を入力します";;
        krn)
            question="$eunit 시리얼 번호의 처음 3자리를 입력하세요";;
        nld)
            question="Voer de eerste 3 tekens van het serienummer van de $eunit in";;
        nor)
            question="Skriv inn de tre første tegnene i serienummeret til $eunit";;
        plk)
            question="Wpisz pierwsze 3 znaki numeru seryjnego $eunit";;
        ptb)
            question="Digite os 3 primeiros caracteres do número de série do $eunit";;
        ptg)
            question="Introduza os primeiros 3 caracteres do número de série do $eunit";;
        rus)
            question="Введите первые 3 символа серийного номера $eunit";;
        spn)
            question="Introduzca los primeros 3 caracteres del número de serie $eunit";;
        sve)
            question="Ange de första 3 tecknen i $eunit serienummer";;
        tha)
            question="ป้อนอักขระ 3 ตัวแรกของหมายเลขซีเรียล $eunit";;
        trk)
            question="$eunit seri numarasının ilk 3 karakterini girin";;
        *) echo "Invalid arg '$1'";;
    esac
}

# Get array of expansion units
if which syno_slot_mapping >/dev/null; then
    #eunits=("$(syno_slot_mapping | grep 'Eunit port' | awk '{print $NF}')")
    #eunits=("$(syno_slot_mapping | grep 'Eunit port')")  # Also show port number
    #readarray -t eunits < <(syno_slot_mapping | grep 'Eunit port' | awk '{print $NF}')
    readarray -t eunits < <(syno_slot_mapping | grep 'Eunit port')  # Also show port number
    if [[ ${#eunits[@]} -gt "0" ]]; then
        for e in "${eunits[@]}"; do
            eunitlist+=("$(echo "$e" | awk '{print $5 "-" $3}')")
        done
    fi
else
#    # Create new /var/log/diskprediction log to ensure newly connected ebox is in latest log
#    # Otherwise the new /var/log/diskprediction log is only created a midnight.
#    /usr/syno/bin/syno_disk_data_collector record
#
#    # Get list of connected expansion units (aka eunit/ebox)
#    path="/var/log/diskprediction"
#    # shellcheck disable=SC2012
#    file=$(ls $path | tail -n1)
#    #eunitlist=($(grep -Eowi "([FRD]XD?[0-9]{3,4})(rp|ii|sas){0,2}" "$path/$file" | uniq))
#    eunitlist=($(grep -Eowi "([FRD]XD?[0-9]{3,4})(rp|ii|sas){0,2}-[0-9]" "$path/$file"))
    
    # Use eunit_inof because "syno_disk_data_collector record" is too slow
    for f in /tmp/eunitinfo_*; do
        # Remove old /tmp/eunitinfo_N files
        if [[ -f "$f" ]]; then
            rm "$f"
        fi
    done
    # Create new /tmp/eunitinfo_N files
    /usr/syno/sbin/eunit_info

    # Get list of connected expansion units (aka eunit/ebox)
    for f in /tmp/eunitinfo_*; do
        if [[ -f "$f" ]]; then
            eunitlist+=("$(synogetkeyvalue "$f" EUnitModel)")
        fi
    done
fi

# Ask user to enter the first 3 characters of their expansion units' serial numbers
if [[ ${#eunitlist[@]} -gt "0" ]]; then
    for eunit in "${eunitlist[@]}"; do
        eunit_lang "$lang"
        echo ""
        # shellcheck disable=SC2162  # read without -r will mangle backslashes
        read -p "${question}: " eunit_serial
        # Pad serial number with xxxx
        if [[ ${eunit_serial:1} =~ [0-9] ]]; then
            eunit_serial="${eunit_serial^^}xxxxxxxxx"
        else
            eunit_serial="${eunit_serial^^}xxxxxxx"
        fi

        convert_serial "$eunit_serial"
        if [[ $lang ]]; then
            made=$(synogetkeyvalue "/usr/syno/synoman/webman/texts/${lang}/strings" version_time)
            echo -e "${eunit} $eunit_serial ${made}: $build_date"
        else
            echo -e "${eunit} $eunit_serial Date Created: $build_date"
        fi
    done
fi

echo ""

exit

