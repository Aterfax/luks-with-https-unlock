#!/bin/bash

# Define your chosen webserver URL.
WEBSERVERURL="https://mybastion.mydomain.com"

################ No user changes needed below this point. ################

# We conduct this check as early as possible to prevent partial execution on any requests targeting a device up front.
requested_device=$1
requested_device_uuid=$(blkid | grep "${requested_device}:" | awk -F '"' '/UUID/ {print $2}')

if [ -n "$requested_device" ]; then
    # Check if the device exists
    if [ ! -b "$requested_device" ]; then
        echo "Error: $requested_device is not a valid device."
        exit 1
    fi

    # Check if the UUID was found
    if [ -z "$requested_device_uuid" ]; then
        echo "Error: No UUID found for $requested_device."
        exit 1
    fi

    # Check if UUID is present in /etc/crypttab
    if ! grep -q "$requested_device_uuid" /etc/crypttab; then
        echo "Error: UUID not found in /etc/crypttab."
        exit 1
    fi
fi

# Function to print a separator line of '=' characters with the current terminal width and desired color
print_separator_line() {
    local term_width=$(tput cols)
    local color=$1

    # ANSI color codes for text
    case $color in
        red)    tput setaf 1 ;;
        green)  tput setaf 2 ;;
        yellow) tput setaf 3 ;;
        blue)   tput setaf 4 ;;
        magenta) tput setaf 5 ;;
        cyan)   tput setaf 6 ;;
        white)  tput setaf 7 ;;
        *)      tput sgr0 ;;  # Default: reset color if not recognized
    esac

    # Print a line of '=' characters in the specified color
    printf '%*s\n' "$term_width" '' | tr ' ' '='

    # Reset color to default
    tput sgr0
}

update_initramfs() {
    # Run the initramfs update command
    sudo update-initramfs -u
    
    # Check if the update was successful
    if [[ $? -eq 0 ]]; then
        initramfsupdated="1"
        echo
        echo "Initramfs has been successfully updated."
    else
        initramfsupdated="0"
        echo
        echo "Failed to update initramfs."
    fi
}

# Function to amend crypttab with keyscript after user confirmation
amend_crypttab_with_keyscript() {
    local uuid=$1  # The selected UUID
    local crypttab_file="/etc/crypttab"

    # Check if the UUID exists in the crypttab file
    if grep -q "UUID=$uuid" "$crypttab_file"; then
        # Extract the original line
        original_line=$(grep "UUID=$uuid" "$crypttab_file")

        # Construct the new line
        new_line=$(echo "$original_line" | sed 's/luks/luks,keyscript=\/bin\/luksunlockhttps/')

        if [ -n "$requested_device" ]; then
            sudo sed -i "s|$original_line|$new_line|" "$crypttab_file"
            crypttabupdated="1"
            return  # Exit early as we have no need to initiate user selection.
        fi

        # Display the new line to the user for confirmation
        echo
        echo "The following change will be made to /etc/crypttab:"
        echo
        echo "Original: $original_line"
        echo "Updated:  $new_line"

        # Ask for user confirmation
        while true; do
            echo
            echo "Do you want to proceed with this update?"
            echo "1. Yes, proceed."
            echo "2. No, abandon automatic update."
            read -r user_choice

            case $user_choice in
                1)
                    # Confirm and apply the change
                    sudo sed -i "s|$original_line|$new_line|" "$crypttab_file"
                    echo
                    echo "Updated crypttab for UUID $uuid."
                    crypttabupdated="1"
                    break
                    ;;
                2)
                    # Abandon the automatic update
                    echo
                    echo "Abandoning automatic update. No changes made."
                    return 0
                    ;;
                *)
                    # Invalid input, ask again
                    echo
                    echo "Invalid choice. Please select 1 to proceed, 2 to abandon the update, or 3 to exit."
                    ;;
            esac
        done
    else
        echo "UUID $uuid not found in /etc/crypttab."
        return 1  # Return with an error code if UUID not found
    fi
}

# Function to add a new LUKS key after user confirmation
addnewlukskey() {
    local device_var=$1
    local UUID=$2
    local WORKDIR=$3  # Directory where the .lek file is located

    # Construct the command
    local keyfile="${WORKDIR}/${UUID}.lek"
    local command="sudo cryptsetup luksAddKey $device_var $keyfile"

    if [ -n "$requested_device" ]; then
        # Slighly different command format to supply the password. printf used to avoid formatting problems caused by echo
        printf "%s" "$LUKSPASSWORD" | cryptsetup --key-file - luksAddKey $device_var $keyfile
        # Check if the command was successful
        if [[ $? -eq 0 ]]; then
            luksaddnewkeysuccess="1"
            echo "LUKS key added successfully."
        else
            luksaddnewkeysuccess="0"
            echo "Failed to add LUKS key."
        fi
        return  # Exit early as we have no need to initiate user selection.
    fi

    # Display the command to the user
    echo "The following command will be executed:"
    echo "$command"

    # Ask for user confirmation
    while true; do
        echo "Do you want to proceed with this command?"
        echo "1. Yes, proceed."
        echo "2. No, abandon automatic update."
        read -r user_choice

        case $user_choice in
            1)
                # Confirm and execute the command
                bash -c "$command"
                
                # Check if the command was successful
                if [[ $? -eq 0 ]]; then
                    luksaddnewkeysuccess="1"
                    echo "LUKS key added successfully."
                else
                    luksaddnewkeysuccess="0"
                    echo "Failed to add LUKS key."
                fi
                break
                ;;
            2)
                # Abandon the automatic update
                echo "Abandoning automatic update. No changes made."
                luksaddnewkeysuccess="0"
                return 0
                ;;
            *)
                # Invalid input, ask again
                echo "Invalid choice. Please select 1 to proceed or 2 to abandon the update."
                ;;
        esac
    done
}

# Function to map UUID to /dev device
get_device_by_uuid() {
    local uuid=$1
    blkid | grep "$uuid" | cut -d: -f1
}

# Function to display available UUIDs and prompt for selection
select_uuid_device() {
    # Parse /etc/crypttab for UUIDs
    crypttab_uuids=($(grep -oP 'UUID=[a-f0-9\-]+' /etc/crypttab | cut -d= -f2))

    # Display available UUIDs and their devices
    echo "Available UUIDs and corresponding devices:"
    for i in "${!crypttab_uuids[@]}"; do
        device=$(get_device_by_uuid "${crypttab_uuids[$i]}")
        echo "$((i+1)). UUID: ${crypttab_uuids[$i]} (Device: $device)"
    done

    # Keep prompting the user until a valid selection is made
    while true; do
        echo "Select an entry by number:"
        read -r selection

        # Validate user input
        if [[ "$selection" -ge 1 && "$selection" -le "${#crypttab_uuids[@]}" ]]; then
            selected_uuid="${crypttab_uuids[$((selection-1))]}"
            selected_device=$(get_device_by_uuid "$selected_uuid")

            echo
            echo "You selected:"
            echo "UUID: $selected_uuid"
            echo "Device: $selected_device"
            echo

            # Store UUID and device in variables for later use
            uuid_blkid=$selected_uuid
            device_var=$selected_device

            break  # Exit loop after valid selection
        else
            echo
            echo "Invalid selection. Please select a valid number."
        fi
    done
}

# Define the important directory paths.
GIT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && cd ../ && pwd )
BIN_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Define helper variables for script logic
setup_choice=""
uuid_blkid=""
device_var=""
crypttabupdated="0"
initramfsupdated="0"
luksaddnewkeysuccess="0"

# Check if the dependencies for a manual install are present.
echo
print_separator_line
echo "Installing dependencies if missing."
${BIN_DIR}/install-dependencies.sh

# Create a working area.
WORKDIR="/tmp/lukskeys"
[ -d "${WORKDIR}" ] || mkdir -p "${WORKDIR}"
chown root:root ${WORKDIR}
chmod 700 ${WORKDIR}
cd ${WORKDIR}

# Make a new UUID for the key and pretouch keyfiles then fix perms to prevent leak.
UUID=$(uuid)
touch ${UUID}.lek
touch ${UUID}.lek.enc
chmod -R 700 ${WORKDIR}

# Define a new password
PW=$(pwgen -Bcnsy 256 -1 | tr -dc 'A-Za-z0-9-_@#$%^&*()')

# Copy hooks after ensuring executability
echo
print_separator_line
echo "Creating new LUKS key: ${WORKDIR}/${UUID}.lek"
dd if=/dev/urandom bs=1 count=256 > "${UUID}.lek"
openssl enc -aes-256-cbc -pbkdf2 -salt -in "${UUID}.lek" -out "${UUID}.lek.enc" -pass pass:"${PW}"

echo
print_separator_line
echo "Creating 'luksunlockhttps' script."

# Created by root, visible only to root.
touch luksunlockhttps
chmod 770 luksunlockhttps

cat <<EOF > luksunlockhttps
#!/bin/sh -e
# Wait 10 seconds for DHCP (needed for Debian 11+12)
if [ \$CRYPTTAB_TRIED -eq "0" ]; then
  sleep 10
fi

# Password for encrypting/decrypting the LUKS key.
# You can generate one with: pwgen -Bcnsy 256 -1 | tr -dc 'A-Za-z0-9-_@#$%^&*()'
DECRYPT_PASSWORD='${PW}'

# Ensure you store the encrypted LUKS key \${UUID}.lek.enc on the webserver of your choice, ensuring the machine has access to this endpoint.
# Set the following variables
UUID='${UUID}'
WEBSERVERURL='${WEBSERVERURL}'
ENCKEYFILENAME="\${UUID}.lek.enc"
# Command to create and encrypt the .lek file to .lek.enc
# UUID=\$(uuid) ; dd if=/dev/urandom bs=1 count=256 > "\${UUID}.lek" ; openssl enc -aes-256-cbc -pbkdf2 -salt -in "\${UUID}.lek" -out "\${UUID}.lek.enc"

# Ensure permissions are as limited as possible up front via chmod.
touch /run/luks.key.enc
chmod 700 /run/luks.key.enc

# The script when invoked will download the encrypted LUKS key as below within the if statement, though if it fails to curl, we drop to asking for password.
if curl -fsS --retry-connrefused --retry 5 \${WEBSERVERURL}/\${ENCKEYFILENAME} -o /run/luks.key.enc; then
  # Decrypt the LUKS key and store it in a temporary file - note that we use a file because we KNOW null bytes will cause issues if using bash variables to store them.
  # We will however, ensure permissions are as limited as possible up front via chmod.
  touch /run/luks.key
  chmod 700 /run/luks.key
  openssl enc -d -aes-256-cbc -pbkdf2 -in /run/luks.key.enc -out /run/luks.key -pass pass:"\${DECRYPT_PASSWORD}" >/dev/null 2>&1

  # Echo the decrypted key so the boot process can grab it to decrypt the boot disk.
  cat /run/luks.key

  # Clean up
  rm /run/luks.key /run/luks.key.enc
  exit
fi

# If the webserver does not answer or the curl command fails we can manually decrypt at the following prompt.
/lib/cryptsetup/askpass "Enter password and press ENTER: "
EOF

# Copy keyscript
echo
print_separator_line
echo "Copying luksunlockhttps script to /bin/luksunlockhttps"
cp luksunlockhttps /bin/luksunlockhttps
chmod 770 /bin/luksunlockhttps

# Copy hooks after ensuring executability
echo
print_separator_line
echo "Copying hooks scripts to /etc/initramfs-tools/hooks/"
chmod +x ${GIT_DIR}/etc/initramfs-tools/hooks/*
cp -R ${GIT_DIR}/etc/initramfs-tools/hooks/. /etc/initramfs-tools/hooks/
echo
print_separator_line blue
echo "Source scripts from ${WORKDIR} now installed locally, please move the ${UUID}.lek.enc file (not ${UUID}.lek) to the correct location on your webserver:"
echo
echo "${WEBSERVERURL}/${UUID}.lek.enc"
echo
print_separator_line blue
echo
print_separator_line red
echo
echo "You should seriously consider taking a backup copy of ${WORKDIR}/${UUID}.lek if this is going to be your only LUKS key. e.g. stored within your chosen password manager."
echo
print_separator_line red

# This is the start of the automatic or manual installation part.

# If not devices was specifically requested then prompt the user for install type.
if [ -z "$requested_device" ]; then

    # Loop to prompt user for valid choice between automatic or manual setup
    while true; do
        echo
        echo "Would you like to use automatic crypttab and initramfs setup, or configure manually?"
        echo "1. Automatic setup"
        echo "2. Manual configuration"
        read -r setup_choice

        # Validate user input
        if [[ "$setup_choice" -eq 1 ]]; then
            echo
            echo "Proceeding with automatic crypttab and initramfs setup."
            break # Valid choice, break the loop and continue with manual setup
        elif [[ "$setup_choice" -eq 2 ]]; then
            echo
            echo "Proceeding with manual configuration."
            break  # Valid choice, break the loop and continue with manual setup
        else
            echo
            echo "Invalid choice. Please select 1 for automatic setup or 2 for manual configuration."
        fi
    done
else
    setup_choice=1
fi

# If user selected automatic configuration start this logic.
if [[ "$setup_choice" -eq 1 ]]; then

    # If the user provided a device then set variables based on it: 
    
    if [ -n "$requested_device" ]; then
        device_var=${requested_device}
        uuid_blkid=${requested_device_uuid}
    else
        # Otherwise ask the user starting by calling the selection function
        select_uuid_device

        # Confirmation prompt
        while true; do
            echo
            echo "Do you confirm this selection? (UUID: $uuid_blkid, Device: $device_var)"
            echo "1. Yes, proceed."
            echo "2. No, restart selection."
            read -r confirm_choice

            case $confirm_choice in
                1)
                    # User confirmed the selection, proceed with the script
                    echo
                    echo "Selection confirmed."
                    break  # Exit the loop and proceed
                    ;;
                2)
                    # User wants to restart selection
                    echo
                    echo "Restarting selection..."
                    select_uuid_device  # Restart the selection process
                    ;;
                *)
                    # Invalid input, ask again
                    echo
                    echo "Invalid choice, please select 1 to confirm or 2 to restart."
                    ;;
            esac
        done
    fi

    # Now amend the crypttab device line
    amend_crypttab_with_keyscript $uuid_blkid
    
    # Now add the new LUKS key to the device
    addnewlukskey "$device_var" "$UUID" "$WORKDIR"

    # Now update the initramfs
    update_initramfs
fi

# Check if crypttabupdated is set to "0"
if [[ "$crypttabupdated" == "0" ]]; then
    print_separator_line red
    echo
    echo "A crypttab automatic update failed or was not requested."
    echo
    echo "You must now amend your /etc/crypttab so the encrypted disk definition line now has the keyscript added, for example:"
    echo
    echo '"dm_crypt-0 UUID=4bb3e10f-e71f-4426-b632-35be29384016 none luks" would become "dm_crypt-0 UUID=4bb3e10f-e71f-4426-b632-35be29384016 none luks,keyscript=/bin/luksunlockhttps"'
    echo
    print_separator_line red
fi

# Check if initramfsupdated is set to "0"
if [[ "$initramfsupdated" == "0" ]]; then
    print_separator_line red
    echo
    echo "A initramfs automatic update failed or was not requested."
    echo
    echo "You must regenerate the initramfs with the command:"
    echo
    echo "sudo update-initramfs -u"
    echo
    print_separator_line red
fi

# Check if initramfsupdated is set to "0"
if [[ "$luksaddnewkeysuccess" == "0" ]]; then
    print_separator_line red
    echo
    echo "Installation of the new LUKS keys failed or was not requested."
    echo
    echo "You must now install the new LUKS key with the command (where /dev/sda3 is an example device):"
    echo
    echo "sudo cryptsetup luksAddKey /dev/sda3 ${WORKDIR}/${UUID}.lek"
    echo
    print_separator_line red
fi

print_separator_line blue
echo
echo "After completing any highlighted manual steps above, please reboot to test functionality. If your /tmp area is not ephemeral, please remember to remove ${WORKDIR}."
echo
print_separator_line blue