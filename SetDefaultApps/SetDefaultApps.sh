#!/bin/zsh
#
# SetDefaultApps.zsh
#
# Authors: Scott Kendall, ecubrooks
# Created:  2025-12-11
# Updated:  2026-01-21
#
# Purpose:
#   Present a SwiftDialog UI that allows a user to set default handlers for
#   selected URL schemes and file extensions using utiluti.
#
# Jamf Script Parameters (4–9):
# $4: Preset name OR comma-separated list of UTIs / URL schemes
#       Presets: browser-only | email-only | docs-only
#       Custom:  https,mailto,pdf,docx,xlsx,txt,md
# $5 = swiftDialog binary path (default: /usr/local/bin/dialog)
# $6 = Jamf policy trigger to install/update swiftDialog
# $7 = Jamf policy trigger to install utiluti
# $8 = Jamf policy trigger to install support files (optional)
# $9 = Support URL (used for Help / QR code)
#
# Change Log:
#   1.0  - Initial
#   1.1  - Removed reliance on system_profiler for faster startup and more reliable system info
#        - Fixed mktemp usage to use SCRIPT_NAME
#        - Improved utiluti detection to avoid needless installs
#   2.0  - Modified script and Added Jamf customization options (presets / user-selected lists)
#
######################################################################################################

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# Script identity (used for temp files and logging)
SCRIPT_NAME="SetDefaultApps"
# Logged-in console user details (used for runAsUser and personalization)
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")

# Basic system metrics
FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$( /usr/bin/sw_vers -productName )
MACOS_VERSION=$( /usr/bin/sw_vers -productVersion )
MAC_RAM=$( /usr/sbin/sysctl -n hw.memsize 2>/dev/null | /usr/bin/awk '{printf "%.0f GB", $1/1024/1024/1024}' )
MAC_CPU=$( /usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null )
# CPU Fallback to uname ONLY if sysctl failed
if [[ -z "$MAC_CPU" ]]; then
    if [[ "$(/usr/bin/uname -m)" == "arm64" ]]; then
        MAC_CPU="Apple Silicon"
    else
        MAC_CPU="Intel"
    fi
fi
# Swift Dialog version requirements
DIALOG_BINARY="${5:-/usr/local/bin/dialog}" # Parameter 5: SwiftDialog binary path
MIN_SD_REQUIRED_VERSION="2.5.0"

if [[ -e "${DIALOG_BINARY}" ]]; then
    SD_VERSION="$("${DIALOG_BINARY}" --version)"
else
    SD_VERSION="0.0.0"
fi

# IT support url
supportURL="${9:-https://support.example.com}"

# Make some temp files

JSON_DIALOG_BLOB=$(mktemp /var/tmp/${SCRIPT_NAME}.XXXXX)
DIALOG_COMMAND_FILE=$(mktemp /var/tmp/${SCRIPT_NAME}.XXXXX)
chmod 644 "$JSON_DIALOG_BLOB"
chmod 644 "$DIALOG_COMMAND_FILE"

# =======================================================================
# Banner Image Logic
# =======================================================================
pick_random_image() {
    # PURPOSE: Return a random banner image URL for Dialog
    # RETURN: URL string
    # List of Image Urls
    local imageurls=(
        # Add urls or local images ex: https://example.com/banner.png"
    )
    # Fallback macOS image (choose file on system)
    local macos_fallback="/Library/Desktop Pictures/Sky.jpg"
    
    # If array is empty, use macOS fallback
    if (( ${#imageurls[@]} == 0 )); then
        printf "%s\n" "$macos_fallback"
        return 0
    fi
    printf "%s\n" "${imageurls[RANDOM % ${#imageurls[@]}]}"
}

# See if there is a "defaults" file...if exists, read in the contents
# Update defaults plist to desired contents
DEFAULTS_DIR="/Library/Managed Preferences/defaults.plist"
if [[ -e $DEFAULTS_DIR ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read $DEFAULTS_DIR "SupportFiles")
    SD_BANNER_LOCAL_IMAGE=$(defaults read $DEFAULTS_DIR "BannerImage")
    SD_BANNER_IMAGE=$SD_BANNER_LOCAL_IMAGE
    spacing=$(defaults read $DEFAULTS_DIR "BannerPadding")
else
    SD_BANNER_IMAGE="$(pick_random_image)"
    spacing=5 #5 spaces to accommodate for icon offset
fi
repeat $spacing BANNER_TEXT_PADDING+=" "

# Display items (banner / icon)
SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Default Apps Selection"
SD_ICON="/System/Applications/App Store.app"
ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
OVERLAY_ICON=$ICON_FILES"ToolbarCustomizeIcon.icns"

# UTI CLI 
UTI_COMMAND="/usr/local/bin/utiluti"

# =======================================================================
# Log files location
# =======================================================================
LOG_FILE="/Library/Logs/${SCRIPT_NAME}.log"

# =======================================================================
# Greeting 
# =======================================================================
hour=${(%):-%D{%H}}
hour=$((10#$hour)) 
greeting=(morning afternoon evening)
SD_DIALOG_GREETING="Good ${greeting[2+($hour>11)+($hour>18)]}"

################################################################################
# Jamf Parameter Parsing (with presets)
################################################################################
# PURPOSE: Interpret Jamf Parameter 4 as either:
#     - a preset name (browser-only | email-only | docs-only), or
#     - a comma-separated list of UTIs / URL schemes (https,mailto,pdf,...)
#
# OUTPUT: UTI_LIST (array)
RAW_UTI_LIST="${4:-docs-only}" # Parameter 4

if [[ -z "$RAW_UTI_LIST" ]]; then
    logMe "ERROR: No UTI list or preset provided"
    exit 1
fi

RAW_UTI_LIST="${RAW_UTI_LIST:l}"
RAW_UTI_LIST="${RAW_UTI_LIST// /}"

case "$RAW_UTI_LIST" in
    browser-only)
        UTI_LIST=(https)
        PRESET_NOTE="**Preset:** Browser defaults only<br><br>"
    ;;
    email-only)
        UTI_LIST=(mailto)
        PRESET_NOTE="**Preset:** Email defaults only<br><br>"
    ;;
    docs-only)
        UTI_LIST=(pdf docx xlsx txt)
        PRESET_NOTE="**Preset:** Document file defaults only<br><br>"
    ;;
    *)
        IFS=',' read -rA UTI_LIST <<< "$RAW_UTI_LIST"
        PRESET_NOTE=""
    ;;
esac

##################################################
#
# Passed in variables
# 
#################################################
# Policy trigger names (Jamf custom triggers)
DIALOG_INSTALL_POLICY="${6:-installswiftDialog}" # Jamf Parameter 6: Jamf policy trigger to install SwiftDialog if missing/outdated
UTILUTI_INSTALL_POLICY="${7:-install_utiluti}" # Jamf Parameter 7: Jamf policy trigger to install utiluti if missing
SUPPORT_FILE_INSTALL_POLICY="${8:-install_support}" # Jamf Parameter 8: Jamf policy trigger to install support files for banner


####################################################################################################
#
# Functions
#
####################################################################################################

function create_log_directory ()
{
    # PURPOSE: Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesn't exist - create it and set the permissions (using zsh parameter expansion to get directory)
	LOG_DIR=${LOG_FILE%/*}
	[[ ! -d "${LOG_DIR}" ]] && /bin/mkdir -p "${LOG_DIR}"
	/bin/chmod 755 "${LOG_DIR}"

	# If the log file does not exist - create it and set the permissions
	[[ ! -f "${LOG_FILE}" ]] && /usr/bin/touch "${LOG_FILE}"
	/bin/chmod 644 "${LOG_FILE}"
}

function logMe () 
{
    # PURPOSE: Basic two pronged logging function that will log like this:
    # 20231204 12:00:00: Log Message
    #    
    # Format: YYYY-MM-DD HH:MM:SS: message
    # This function logs both to STDOUT/STDERR and a file
    # The log file is set by the $LOG_FILE variable.
    #
    # RETURN: None
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}" 1>&2
}

function install_swift_dialog ()
{
    # PURPOSE: Install Swift dialog From JAMF 
    # PARMS Expected: DIALOG_INSTALL_POLICY - policy trigger from JAMF
    #
    # RETURN: None
    
    /usr/local/bin/jamf policy -trigger ${DIALOG_INSTALL_POLICY}
}


function check_swift_dialog_install ()
{
    # PURPOSE: Check to make sure that Swift Dialog is installed and meets minimum required version
    # If missing/outdated, install via Jamf policy trigger.
    #
    # RETURN: None

    logMe "Ensuring that swiftDialog version is installed..."
    if [[ ! -x "${DIALOG_BINARY}" ]]; then
        logMe "Swift Dialog is missing or corrupted - Installing from JAMF"
        install_swift_dialog
        SD_VERSION=$( ${DIALOG_BINARY} --version)        
    fi

    if ! is-at-least "${MIN_SD_REQUIRED_VERSION}" "${SD_VERSION}"; then
        logMe "Swift Dialog is outdated - Installing version '${MIN_SD_REQUIRED_VERSION}' from JAMF..."
        install_swift_dialog
    else    
        logMe "Swift Dialog is currently running: ${SD_VERSION}"
    fi
}

function check_support_files ()
{
    # PURPOSE: Ensure required support assets exist: swift, banner_image and uti
    #
    # RETURN: None
    
    check_swift_dialog_install
    
    # Optional: Remove comment # to check if local banner image exists
    #if [[ ! -e "${SD_BANNER_LOCAL_IMAGE}" ]]; then
    #    /usr/local/bin/jamf policy -trigger "${SUPPORT_FILE_INSTALL_POLICY}"
    #fi
    
    if [[ "$(which utiluti 2>/dev/null)" == *"not found"* ]]; then
        /usr/local/bin/jamf policy -trigger "${UTILUTI_INSTALL_POLICY}"
    fi
}
function create_infobox_message()
{
	# Swift Dialog infoBox message construct, feel free to update.
    # PURPOSE: Build the "infobox" string shown in SwiftDialog.
    #
    # RETURN: None
    
	SD_INFO_BOX_MSG="## System Info ##<br>"
    SD_INFO_BOX_MSG+="<br>"
    SD_INFO_BOX_MSG+="{computername}"
    SD_INFO_BOX_MSG+="<br>"
    SD_INFO_BOX_MSG+="macOS {osname} {osversion}"
    SD_INFO_BOX_MSG+="<br>"
	#SD_INFO_BOX_MSG+="${MAC_CPU}<br>"  # remove hash if you wish to use
    #SD_INFO_BOX_MSG+="<br>"
    SD_INFO_BOX_MSG+="{computermodel}"
    SD_INFO_BOX_MSG+="<br>"
	SD_INFO_BOX_MSG+="{serialnumber}"
}

function cleanup_and_exit ()
{
    
    # PURPOSE: Remove temp files (if present) and exit with provided code.
    #
    # PARMS: $1 = exit code
    #
    # RETURN: exits script
    if [[ -f "${JSON_DIALOG_BLOB}" ]]; then
        /bin/rm -rf "${JSON_DIALOG_BLOB}"
    fi
    
    if [[ -f "${DIALOG_COMMAND_FILE}" ]]; then
        /bin/rm -rf "${DIALOG_COMMAND_FILE}"
    fi
    
    exit "$1"
}

function runAsUser () 
{
    # PURPOSE: Run a command as the currently logged in user (console user).
    #
    # PARMS: $@ = command and arguments to execute
    #
    # RETURN: Command output
    launchctl asuser "$USER_UID" sudo -u "$LOGGED_IN_USER" "$@"
}

function get_uti_results ()
{
    # PURPOSE: Format the uti results into an array and remove the files that are not in the /Applications or /System/Applications folder
    # PRAMS: $1 = utiluti extension to look up
    # RETURN: A formatted list of applications
    # EXPECTED: None
    declare utiResults
    declare cleanResults
    declare -a resultsArray
    declare -a cleanArray
    case "${1:l}" in
        https|ftp|ssh|mailto)
            utiResults=$(runAsUser $UTI_COMMAND url list "${1:l}")
        ;;
        *)
            utiResults=""  # force the if utiResults
        ;;
    esac
    
    # The default list function returned blank, so we need to locate this another way
    if [[ -z "${utiResults}" ]]; then
        utiResults="$(runAsUser "$UTI_COMMAND" get-uti "${1:l}")"
        if [[ -z "${utiResults}" ]]; then
            logMe "WARNING: get-uti returned blank for '${1:l}'"
        fi
        utiResults="$(runAsUser "$UTI_COMMAND" type list "${utiResults}")"
    fi
    
    # Remove the prefixes from the app names
    cleanResults=$(echo "${utiResults}" |  grep -E '^(/System|/Applications)' | sed -e 's|^/Applications/||' -e 's|^/System/Applications/||' -e 's|^/System/Volumes/Preboot/Cryptexes/App/System/Applications/||' -e 's|^/System/Library/CoreServices/||' ) #remove the prefixes from the app names
    resultsArray=("${(@f)cleanResults}")
    for item in "${resultsArray[@]}"; do
        cleanArray+=("\"${item}\"",)
    done
    echo ${cleanArray[@]}
}

function get_default_uti_app ()
{
    # PURPOSE: Determine the current default app for the uti prefix
    # PRAMS: $1 = utiluti command to run
    # RETURN: app assigned to that uti
    # EXPECTED: None
    utiResults=$(runAsUser $UTI_COMMAND url ${1})
    if [[ "${utiResults}" == '<no default app found>' ]]; then # the default list function returned blank, so we need to locate this another way
        utiType=$(runAsUser $UTI_COMMAND get-uti ${1})
        utiResults=$(runAsUser $UTI_COMMAND type ${utiType})
    fi
    echo $utiResults |  grep -E '^(/System|/Applications)' | sed -e 's|^/Applications/||' -e 's|^/System/Applications/||' -e 's|^/System/Volumes/Preboot/Cryptexes/App/System/Applications/||' -e 's|^/System/Library/CoreServices/||'
}

function set_uti_results ()
{
    # PURPOSE: Set the default handler for a URL scheme OR file type (via UTI)  based on a selected app
    # PRAMS:
    #   $1 = Default Application name (e.g., "Safari.app") - may include quotes
    #   $2 = URL scheme OR file extension token (https, mailto, pdf, docx, etc.)
    # RETURN: 0 on skip (no selection), otherwise bubbles utiluti outcome to logs
    # EXPECTED: None

    declare tmp
    declare bundleId
    declare appName="${1//\"/}" 
    declare filePath
    declare results
    
    # Check if appname is blank or null
    if [[ -z "$appName" || "$appName" == "null" ]]; then
        logMe "Skipping $2 (no app selected)"
        return 0
    fi

    # Locate where the file is on the system
    if [[ -e "/Applications/$appName" ]]; then
        filePath="/Applications/$appName"
    elif [[ -e "/System/Applications/$appName" ]]; then
        filePath="/System/Applications/$appName"
    else
        filePath="/System/Library/CoreServices/$appName"
    fi

    # Look up the bundleID of the app that we are changing
    bundleId=$(runAsUser $UTI_COMMAND app id "${filePath}")
    if [[ -z "$bundleId" || "$bundleId" == "null" ]]; then    
        logMe "ERROR: Could not determine bundleId for '$appName' ($filePath)"
        return 1
    fi


    # Evaluate the options and set the UTI command accordingly    
    case "${2:l}" in
        http|https|ftp|mailto)
            results=$(runAsUser "$UTI_COMMAND" url set "${2:l}" "$bundleId")
        ;;
        *)
            defaultBundleId=$(runAsUser "$UTI_COMMAND" get-uti "$2")
            if [[ -z "$defaultBundleId" || "$defaultBundleId" == "null" ]]; then
                logMe "ERROR: Could not determine UTI for '$2' (defaultBundleId blank)"
                return 1
            fi
            results=$(runAsUser "$UTI_COMMAND" type set "$defaultBundleId" "$bundleId")
        ;;
    esac

    logMe "Results: $results"
}

function construct_dialog_header_settings ()
{
    # PURPOSE:
    #   Construct the common SwiftDialog JSON header used for the window.
    #   This is written to STDOUT and redirected to JSON_DIALOG_BLOB.
    #
    # VARIABLES expected:
    #   SD_ICON, SD_BANNER_IMAGE, SD_INFO_BOX_MSG, OVERLAY_ICON,
    #   SD_WINDOW_TITLE, SD_VERSION, supportURL, LOGGED_IN_USER, USER_UID
    #
    # PARMS:
    #   $1 = message string displayed at the top of the dialog
    #
    # RETURN: JSON snippet

    # =======================================================================
    # Help Message Variables
    # =======================================================================
    
    help_message="**App Usage:** Choose what application(s) you want to open a particular type of file with dropdown menu(s).<br><br>**Support Info:** Click on the 'More Info' button for support or scan QR code. Please use provide the following information:<br><br>**User Info:** <br>- **Full Name:** {userfullname}<br>- **User Account Name:** ${LOGGED_IN_USER}<br>- **User ID:** ${USER_UID}<br><br>**Computer Information:**<br>- **macOS:** {osversion} ({osname})<br>- **Computer Name:** {computername}<br>- **Serial Number:** {serialnumber}<br><br>**Dialog:** <br>- **Version:** ${SD_VERSION}"
    
    helpimage="qr=${supportURL}"

	echo '{
        "icon" : "'${SD_ICON}'",
        "message" : "'$1'",
        "bannerimage" : "'${SD_BANNER_IMAGE}'",
        "infobox" : "'${SD_INFO_BOX_MSG}'",
        "overlayicon" : "'${OVERLAY_ICON}'",
        "ontop" : "true",
        "bannertitle" : "'${SD_WINDOW_TITLE}'",
        "titlefont" : "name=Avenir Next,shadow=1",
        "helpmessage" : "'${help_message}'",
        "helpimage" : "'"${helpimage}"'",
        "infobutton" : "More Info",
        "infobuttonaction" : "'${supportURL}'",        
        "width" : 920,
        "height" : 520,
        "button1text" : "OK",
        "button2text" : "Cancel",
        "moveable" : "true",
        "json" : "true", 
        "quitkey" : "0",
        "messageposition" : "top",'
}

function create_dropdown_message_body ()
{
    # PURPOSE: Create the dropdown list for the dialog box
    # EXPECTED: JSON_DIALOG_BLOB exists and is writable
    # PRAMS:
    #   $1 = Label/title shown in Dialog (e.g., "Web Browser (https):")
    #   $2 = Dropdown "values" list as JSON array items (e.g., "\"Safari.app\",\"Chrome.app\"")
    #   $3 = Default selected value (optional)
    #   $4 = Position marker: first | last | (anything else = middle)
    #   $5 = (unused by current calls; preserved)
    #   $6 = Field name + required flag (optional)
    
    local line=""
    local pos="${4:l}"
    local values="$2"
    
    # HARD TRIM: kill trailing comma if present
    values="${values%,}"
    
    if [[ "$pos" == "first" ]]; then
        line+='"selectitems" : ['
    fi
    
    if [[ -n "$1" ]]; then
        line+="{\"title\" : \"$1\", \"values\" : [$values]"
        [[ -n "$3" ]] && line+=', "default" : "'"$3"'"'
        [[ -n "$6" ]] && line+=', "name" : "'"$6"'", "required" : "true"'
        line+="}"
    fi
    
    if [[ "$pos" == "last" ]]; then
        line+="],"
    fi
    echo "$line" >> "$JSON_DIALOG_BLOB"
}

####################################################################################################
#
# Main Script
#
####################################################################################################

# Arrays used to store the available application values for each file type
declare -a utiHttp
declare -a utiMailTo
declare -a utiFtp
declare -a utiXLS
declare -a utiDoc
declare -a utiTxt
declare -a utiPDF

# SwiftDialog helper autoload (version compare)
autoload -Uz 'is-at-least'

# Setup logging / dependencies / UI info
create_log_directory
check_support_files
create_infobox_message

# Build application lists for each supported item (values for dropdowns)
logMe "Constructing application list(s)"
utiMailTo=$(get_uti_results "mailto")
utiHttp=$(get_uti_results "https")
utiFtp=$(get_uti_results "ftp")
utiXLS=$(get_uti_results "xlsx")
utiDoc=$(get_uti_results "docx")
utiTxt=$(get_uti_results "txt")
utiPDF=$(get_uti_results "pdf")
utiMd=$(get_uti_results "md")

# Construct the SwiftDialog JSON payload in JSON_DIALOG_BLOB
logMe "Constructing display options"
message="$SD_DIALOG_GREETING, {userfullname}.<br><br>Current default applications for each file type(s) are shown below.  You can optionally change which applications will be used when you open the following types of files:"
construct_dialog_header_settings "$message" > "${JSON_DIALOG_BLOB}"
create_dropdown_message_body "" "" "" "first"
# Add dropdown items conditionally based on UTI_LIST
# FIRST_ITEM controls commas between JSON objects
# if you need to add new app types in here, make sure to use this template:
# [[ "$FIRST_ITEM" == false ]] && echo "," >> "$JSON_DIALOG_BLOB"
# FIRST_ITEM=false
# create_dropdown_message_body "Documents (doc):" "$utiDoc" "$(get_default_uti_app "docx")"
#
# You need to copy/edit/paste lines above into the code in if statement
FIRST_ITEM=true
if [[ " ${UTI_LIST[*]} " == *" mailto "* ]]; then
    [[ "$FIRST_ITEM" == false ]] && echo "," >> "$JSON_DIALOG_BLOB"
    FIRST_ITEM=false
    create_dropdown_message_body "Email App (mailto):" "$utiMailTo" "$(get_default_uti_app "mailto")"
fi

if [[ " ${UTI_LIST[*]} " == *" https "* ]]; then
    [[ "$FIRST_ITEM" == false ]] && echo "," >> "$JSON_DIALOG_BLOB"
    FIRST_ITEM=false
    create_dropdown_message_body "Web Browser (https):" "$utiHttp" "$(get_default_uti_app "https")"
fi

if [[ " ${UTI_LIST[*]} " == *" ftp "* ]]; then
    [[ "$FIRST_ITEM" == false ]] && echo "," >> "$JSON_DIALOG_BLOB"
    FIRST_ITEM=false
    create_dropdown_message_body "File Transfer (ftp):" "$utiFtp" "$(get_default_uti_app "ftp")"
fi

if [[ " ${UTI_LIST[*]} " == *" xlsx "* ]]; then
    [[ "$FIRST_ITEM" == false ]] && echo "," >> "$JSON_DIALOG_BLOB"
    FIRST_ITEM=false
    create_dropdown_message_body "Spreadsheet (xlsx):" "$utiXLS" "$(get_default_uti_app "xlsx")"
fi

if [[ " ${UTI_LIST[*]} " == *" docx "* ]]; then
    [[ "$FIRST_ITEM" == false ]] && echo "," >> "$JSON_DIALOG_BLOB"
    FIRST_ITEM=false
    create_dropdown_message_body "Documents (docx):" "$utiDoc" "$(get_default_uti_app "docx")"
fi

if [[ " ${UTI_LIST[*]} " == *" txt "* ]]; then
    [[ "$FIRST_ITEM" == false ]] && echo "," >> "$JSON_DIALOG_BLOB"
    FIRST_ITEM=false
    create_dropdown_message_body "Text Files (txt):" "$utiTxt" "$(get_default_uti_app "txt")"
fi

if [[ " ${UTI_LIST[*]} " == *" md "* ]]; then
    [[ "$FIRST_ITEM" == false ]] && echo "," >> "$JSON_DIALOG_BLOB"
    FIRST_ITEM=false
    create_dropdown_message_body "Markdown (md):" "$utiMd" "$(get_default_uti_app "md")"
fi

if [[ " ${UTI_LIST[*]} " == *" pdf "* ]]; then
    [[ "$FIRST_ITEM" == false ]] && echo "," >> "$JSON_DIALOG_BLOB"
    FIRST_ITEM=false
    create_dropdown_message_body "Portable Doc Format (pdf):" "$utiPDF" "$(get_default_uti_app "pdf")"
fi
echo "]}" >> "$JSON_DIALOG_BLOB"

# Show the dialog screen and get the results
results="$("${DIALOG_BINARY}" --json --jsonfile "${JSON_DIALOG_BLOB}" 2>/dev/null)"
returnCode=$?

# Cancel button
if [[ "$returnCode" == 2 ]]; then
    logMe "Cancel button pressed"
    cleanup_and_exit 0
fi

# Extract the selected values from results 
if [[ " ${UTI_LIST[*]} " == *" mailto "* ]]; then
    resultsMailTo=$(echo "$results" | grep -A2 "Email App (mailto):" | grep -o '"selectedValue" *: *"[^"]*"' | cut -d'"' -f4)
fi
if [[ " ${UTI_LIST[*]} " == *" http "* ]]; then
    resultsHttp=$(echo "$results" | grep -A2 "Web Browser (http):" | grep -o '"selectedValue" *: *"[^"]*"' | cut -d'"' -f4)
fi
if [[ " ${UTI_LIST[*]} " == *" ftp "* ]]; then
    resultsFtp=$(echo "$results" | grep -A2 "File Transfer (ftp):" | grep -o '"selectedValue" *: *"[^"]*"' | cut -d'"' -f4)
fi
if [[ " ${UTI_LIST[*]} " == *" xlsx "* ]]; then
    resultsXls=$(echo "$results" | grep -A2 "Spreadsheet (xlsx):" | grep -o '"selectedValue" *: *"[^"]*"' | cut -d'"' -f4)
fi
if [[ " ${UTI_LIST[*]} " == *" docx "* ]]; then
    resultsDoc=$(echo "$results" | grep -A2 "Documents (docx):" | grep -o '"selectedValue" *: *"[^"]*"' | cut -d'"' -f4)
fi
if [[ " ${UTI_LIST[*]} " == *" txt "* ]]; then
    resultsTxt=$(echo "$results" | grep -A2 "Text Files (txt):" | grep -o '"selectedValue" *: *"[^"]*"' | cut -d'"' -f4)
fi
if [[ " ${UTI_LIST[*]} " == *" pdf "* ]]; then
    resultsPDF=$(echo "$results" | grep -A2 "Portable Doc Format (pdf):" | grep -o '"selectedValue" *: *"[^"]*"' | cut -d'"' -f4)
fi
if [[ " ${UTI_LIST[*]} " == *" md "* ]]; then
    resultsMD=$(echo "$results" | grep -A2 "Markdown (md):" | grep -o '"selectedValue" *: *"[^"]*"' | cut -d'"' -f4)
fi

# Apply selected defaults via utiluti
# Call the "set_uti" function to set the results
if [[ " ${UTI_LIST[*]} " == *" mailto "* ]]; then
    set_uti_results "$resultsMailTo" "mailto"
fi
if [[ " ${UTI_LIST[*]} " == *" http "* ]]; then
    set_uti_results "$resultsHttp" "http"
fi
if [[ " ${UTI_LIST[*]} " == *" ftp "* ]]; then
    set_uti_results "$resultsFtp" "ftp"
fi
if [[ " ${UTI_LIST[*]} " == *" xlsx "* ]]; then
    set_uti_results "$resultsXls" "xlsx"
fi
if [[ " ${UTI_LIST[*]} " == *" docx "* ]]; then
    set_uti_results "$resultsDoc" "docx"
fi
if [[ " ${UTI_LIST[*]} " == *" txt "* ]]; then
    set_uti_results "$resultsTxt" "txt"
fi
if [[ " ${UTI_LIST[*]} " == *" pdf "* ]]; then
    set_uti_results "$resultsPDF" "pdf"
fi
if [[ " ${UTI_LIST[*]} " == *" md "* ]]; then
    set_uti_results "$resultsMD" "md"
fi

#===============================================================================
#=== Cleanup
#===============================================================================
cleanup_and_exit 0