#!/bin/bash

# Global Variables
SAMBA_CONF="/etc/samba/smb.conf"
SAMBA_CONF_BACKUP="${SAMBA_CONF}.$(date +%Y%m%d_%H%M%S).bak"
DEFAULT_GUEST_SHARE_PATH="/srv/samba/guest"

# Error messages
error_exit() {
  echo "ERROR: $1" >&2
  exit 1
}

# check if the script is running as root
check_root() {
  echo "-------------------------------------------------------------------"
  echo "  Checking for root privileges..."
  if [ "$EUID" -ne 0 ]; then
    echo "  ERROR: This script requires root privileges to configure Samba."
    echo "  Please run it using 'sudo':"
    echo "  sudo ./$(basename "$0")"
    echo "-------------------------------------------------------------------"
    exit 1
  fi
  echo "  Root privileges confirmed."
  echo "-------------------------------------------------------------------"
}

# install Samba
install_samba() {
  echo "-------------------------------------------------------------------"
  echo "  Checking for Samba and related packages installation..."
  if ! rpm -q samba-common &>/dev/null; then
    echo "  Samba or related packages are not installed. Attempting to install them now..."
    dnf up --ref --assumeyes || error_exit "Failed to check for DNF updates."
    dnf install -y samba samba-client cifs-utils || error_exit "Failed to install Samba, samba-client, or cifs-utils."
    echo "  Samba and related packages installed successfully."
  else
    echo "  Samba and related packages are already installed."
  fi

  echo "  Ensuring Samba services are enabled and running..."
  systemctl enable smb nmb || echo "  Warning: Failed to enable smb/nmb services."
  systemctl start smb nmb || echo "  Warning: Failed to start smb/nmb services. Check service status manually."
  echo "-------------------------------------------------------------------"
}

# configure a Samba share
configure_single_share() {
  local share_name=""
  local share_path=""
  local browseable="yes"
  local writable="yes"
  local guest_ok="no"
  local read_only="no" # Derived from writable
  local valid_users=""
  local create_mask="0664"
  local directory_mask="0775"
  local chosen_owner="nobody:nobody" # Default owner
  local chosen_chmod="0775"          # Default chmod

  clear
  echo "-------------------------------------------------------------------"
  echo "  --- Configuring New Samba Share ---"
  echo "-------------------------------------------------------------------"

  # Ask for Share Name
  while true; do
    read -rp "  Enter the Samba share name (e.g., 'MyPublicShare', 'FamilyPhotos'): " share_name
    if [ -z "$share_name" ]; then
      echo "  Share name cannot be empty. Please try again."
    else
      if [[ "$share_name" =~ [[:space:]] ]]; then
        echo "  Share name should ideally not contain spaces. Please use underscores or dashes if needed."
        continue
      fi
      break
    fi
  done

  echo "  Default share path will be: /srv/samba/${share_name}"
  read -rp "  Enter the full path for this share (leave empty for default '/srv/samba/${share_name}'): " custom_share_path
  if [ -z "$custom_share_path" ]; then
    share_path="/srv/samba/${share_name}"
  else
    share_path=$(echo "$custom_share_path" | sed 's:/*$::') # Remove trailing slash
  fi

  echo "  Share directory will be: '$share_path'"

  local parent_dir="$(dirname "$share_path")"
  if ! mountpoint -q "$share_path" && ! mountpoint -q "$parent_dir"; then
    echo "  Warning: '$share_path' or its parent '$parent_dir' does not appear to be on a mounted filesystem."
    echo "          Please ensure your storage is correctly mounted before proceeding."
    read -rp "  Do you want to continue despite this warning? (y/N): " continue_warn
    continue_warn=${continue_warn:-N}
    if [[ ! "$continue_warn" =~ ^[Yy]$ ]]; then
      echo "  Aborting share configuration for '$share_name'."
      return 1
    fi
  fi

  read -rp "  Proceed with creating this directory if it doesn't exist? (Y/n): " create_dir_confirm
  create_dir_confirm=${create_dir_confirm:-Y}
  if [[ "$create_dir_confirm" =~ ^[Yy]$ ]]; then
    if [ ! -d "$share_path" ]; then
      echo "  Creating directory '$share_path'..."
      mkdir -p "$share_path" || error_exit "Failed to create directory '$share_path'."
      echo "  Directory created."
    else
      echo "  Directory '$share_path' already exists."
    fi
  else
    echo "  Skipping directory creation. Please ensure '$share_path' exists and is accessible."
  fi
  clear

  # Directory Permissions
  echo "-------------------------------------------------------------------"
  echo "  --- Share Directory Permissions ---"
  echo "-------------------------------------------------------------------"
  echo "  Default ownership: nobody:nobody (chown -R nobody:nobody)"
  read -rp "  Enter custom ownership (e.g., 'user:group', leave empty for default): " custom_owner
  if [ -n "$custom_owner" ]; then
    chosen_owner="$custom_owner"
  fi
  echo "  Using ownership: '$chosen_owner'"

    # Validate and Create User/Group for chosen_owner
    local owner_user=$(echo "$chosen_owner" | cut -d: -f1)
    local owner_group=$(echo "$chosen_owner" | cut -d: -f2)

    # Check and create user if it doesn't exist (unless it's 'nobody')
    if [ "$owner_user" != "nobody" ] && ! id "$owner_user" &>/dev/null; then
        read -rp "  System user '$owner_user' does not exist. Create it (no home dir, no login shell)? (Y/n): " create_owner_user_confirm
        create_owner_user_confirm=${create_owner_user_confirm:-Y}
        if [[ "$create_owner_user_confirm" =~ ^[Yy]$ ]]; then
            echo "  Creating system user '$owner_user'..."
            useradd -M -s /sbin/nologin "$owner_user"
            if [ $? -eq 0 ]; then
                echo "  System user '$owner_user' created successfully."
            else
                echo "  Warning: Failed to create system user '$owner_user'. Please create it manually if needed."
                # Fallback to nobody:nobody if user creation fails
                chosen_owner="nobody:nobody"
                owner_user="nobody"
                owner_group="nobody" 
            fi
        else
            echo "  Skipping creation of system user '$owner_user'. Share ownership might default or require manual adjustment."
            # Fallback to nobody:nobody if user creation is skipped
            chosen_owner="nobody:nobody"
            owner_user="nobody"
            owner_group="nobody" 
        fi
    fi

    # Check and create group if it doesn't exist (unless it's 'nobody')
    if [ -n "$owner_group" ] && [ "$owner_group" != "nobody" ] && ! getent group "$owner_group" &>/dev/null; then
        read -rp "  Group '$owner_group' does not exist. Create it? (Y/n): " create_owner_group_confirm
        create_owner_group_confirm=${create_owner_group_confirm:-Y}
        if [[ "$create_owner_group_confirm" =~ ^[Yy]$ ]]; then
            echo "  Creating group '$owner_group'..."
            groupadd "$owner_group"
            if [ $? -eq 0 ]; then
                echo "  Group '$owner_group' created successfully."
                if id "$owner_user" &>/dev/null && ! id -nG "$owner_user" | grep -qw "$owner_group"; then
                    echo "  Adding user '$owner_user' to new group '$owner_group'..."
                    usermod -aG "$owner_group" "$owner_user" || echo "  Warning: Failed to add user '$owner_user' to group '$owner_group'."
                fi
            else
                echo "  Warning: Failed to create group '$owner_group'. Ownership might default or require manual adjustment."
                # Fallback to nobody:nobody if group creation fails
                chosen_owner="nobody:nobody"
            fi
        else
            echo "  Skipping creation of group '$owner_group'. Share ownership might default or require manual adjustment."
            chosen_owner="nobody:nobody"
        fi
    fi
    # Re-assemble chosen_owner in case of fallbacks
    chosen_owner="${owner_user}:${owner_group}"


  echo "  Default permissions: 0775 (chmod -R 0775)"
  read -rp "  Enter custom permissions (e.g., '0770', leave empty for default): " custom_chmod
  if [ -n "$custom_chmod" ]; then
    if [[ ! "$custom_chmod" =~ ^[0-7]{3,4}$ ]]; then
      echo "  Warning: Invalid chmod format. Using default '0775'."
      chosen_chmod="0775"
    else
      chosen_chmod="$custom_chmod"
    fi
  fi
  echo "  Using permissions: '$chosen_chmod'"

  echo "  Applying permissions to '$share_path'..."
  chown -R "$chosen_owner" "$share_path" || echo "  Warning: Failed to chown '$share_path'. Manual intervention might be needed."
  chmod -R "$chosen_chmod" "$share_path" || echo "  Warning: Failed to chmod '$share_path'. Manual intervention might be needed."
  echo "  Permissions applied."
  clear

  # Share Properties
  echo "-------------------------------------------------------------------"
  echo "  --- Samba Share Properties for [${share_name}] ---"
  echo "-------------------------------------------------------------------"

  # Browseable
  read -rp "  Make this share browseable (visible in network)? (Y/n, default: yes): " input
  input=${input:-Y}
  [[ "$input" =~ ^[Nn]$ ]] && browseable="no"

  # Writable (and derive read only)
  read -rp "  Make this share writable? (Y/n, default: yes): " input
  input=${input:-Y}
  if [[ "$input" =~ ^[Nn]$ ]]; then
    writable="no"
    read_only="yes"
  else
    writable="yes"
    read_only="no"
  fi

  # Guest OK
  read -rp "  Allow guest access (no password)? (y/N, default: no): " input
  input=${input:-N}
  [[ "$input" =~ ^[Yy]$ ]] && guest_ok="yes"

  # Valid Users
  if [[ "$guest_ok" == "no" ]]; then
    read -rp "  Enter valid system users (comma-separated, e.g., user1,user2, leave empty for no specific users): " valid_users
  fi

  # Create Mask
  read -rp "  Enter create mask for new files (default: 0664): " input
  input=${input:-0664}
  create_mask="$input"

  # Directory Mask
  read -rp "  Enter directory mask for new directories (default: 0775): " input
  input=${input:-0775}
  directory_mask="$input"

  clear
  # Append to smb.conf
  echo "-------------------------------------------------------------------"
  echo "  Appending share configuration to '$SAMBA_CONF'..."
  echo "-------------------------------------------------------------------"
  {
    echo ""
    echo "[${share_name}]"
    echo "  path = ${share_path}"
    echo "  browseable = ${browseable}"
    echo "  writable = ${writable}"
    echo "  guest ok = ${guest_ok}"
    echo "  read only = ${read_only}"
    [ -n "$valid_users" ] && echo "  valid users = ${valid_users}"
    echo "  create mask = ${create_mask}"
    echo "  directory mask = ${directory_mask}"
  } | tee -a "$SAMBA_CONF" >/dev/null

  if [ $? -eq 0 ]; then
    echo "  Share '[${share_name}]' added to '$SAMBA_CONF'."
  else
    echo "  Error: Failed to append share configuration to '$SAMBA_CONF'."
    return 1
  fi
  echo "-------------------------------------------------------------------"
  return 0
}

# add Samba users interactively
add_samba_users() {
  clear
  echo "-------------------------------------------------------------------"
  echo "  --- Samba User Configuration ---"
  echo "-------------------------------------------------------------------"
  echo "  You can now add system users to Samba's password database."
  echo "  Users added here will be able to access Samba shares requiring authentication."

  while true; do
    read -rp "  Do you want to add a Samba user? (y/N): " add_user_confirm
    add_user_confirm=${add_user_confirm:-N}

    if [[ "$add_user_confirm" =~ ^[Yy]$ ]]; then
      read -rp "  Enter the system username to add to Samba: " samba_user
      if [ -z "$samba_user" ]; then
        echo "  Username cannot be empty. Skipping."
        continue
      fi

      if ! id "$samba_user" &>/dev/null; then
        echo "  System user '$samba_user' does not exist."
        read -rp "  Do you want to create this system user (with no home dir and no login shell)? (Y/n): " create_system_user_confirm
        create_system_user_confirm=${create_system_user_confirm:-Y}

        if [[ "$create_system_user_confirm" =~ ^[Yy]$ ]]; then
          echo "  Creating system user '$samba_user'..."
          useradd -M -s /sbin/nologin "$samba_user"
          if [ $? -eq 0 ]; then
            echo "  System user '$samba_user' created successfully."

            read -rp "  Do you want to add '$samba_user' to a specific group (e.g., 'samba_users', 'nobody')? (y/N): " add_to_group_confirm
            add_to_group_confirm=${add_to_group_confirm:-N}
            if [[ "$add_to_group_confirm" =~ ^[Yy]$ ]]; then
                read -rp "  Enter the group name: " target_group
                if [ -n "$target_group" ]; then
                    if getent group "$target_group" &>/dev/null; then
                        echo "  Adding user '$samba_user' to group '$target_group'..."
                        usermod -aG "$target_group" "$samba_user"
                        if [ $? -eq 0 ]; then
                            echo "  User '$samba_user' added to group '$target_group'."
                        else
                            echo "  Warning: Failed to add user '$samba_user' to group '$target_group'."
                        fi
                    else
                        echo "  Warning: Group '$target_group' does not exist. Skipping group addition."
                    fi
                else
                    echo "  No group specified. Skipping group addition."
                fi
            fi

          else
            echo "  Error: Failed to create system user '$samba_user'. Skipping Samba user creation."
            continue
          fi
        else
          echo "  Skipping system user creation. Therefore, cannot add '$samba_user' to Samba."
          continue
        fi
      fi

      echo "  Adding '$samba_user' to Samba password database. You will be prompted for a password."
      smbpasswd -a "$samba_user"
      if [ $? -eq 0 ]; then
        echo "  User '$samba_user' added to Samba successfully."
      else
        echo "  Error: Failed to add user '$samba_user' to Samba. Check logs."
      fi
    else
      echo "  No more Samba users will be added."
      break
    fi
  done
  echo "-------------------------------------------------------------------"
}

# configure Firewalld for Samba
configure_firewalld() {
  clear
  echo "-------------------------------------------------------------------"
  echo "  --- Configuring Firewalld for Samba ---"
  echo "-------------------------------------------------------------------"

  if systemctl is-active firewalld &>/dev/null; then
    echo "  Firewalld service is running. Opening Samba ports (139, 445)..."
    firewall-cmd --permanent --zone=public --add-service=samba >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "  Samba service added permanently to firewalld."
      echo "  Reloading firewalld to apply changes..."
      firewall-cmd --reload >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        echo "  Firewalld reloaded successfully. Samba ports are now open."
      else
        echo "  Error: Failed to reload firewalld. Manual reload might be needed."
      fi
    else
      echo "  Error: Failed to add Samba service to firewalld. Check firewalld status."
    fi
  else
    echo "  Firewalld service is not running. Skipping Firewalld configuration."
    echo "  Ensure your firewall allows Samba traffic (ports 139, 445) if you have another firewall solution."
  fi
  echo "-------------------------------------------------------------------"
  sleep 10
}

# configure SELinux for Samba
configure_selinux() {
  clear
  echo "-------------------------------------------------------------------"
  echo "  --- Configuring SELinux for Samba ---"
  echo "-------------------------------------------------------------------"

  if type getenforce &>/dev/null && type setsebool &>/dev/null; then
    local selinux_status=$(getenforce)
    echo "  SELinux status: $selinux_status"

    if [ "$selinux_status" == "Enforcing" ]; then
      echo "  Setting SELinux boolean 'samba_enable_home_dirs' to 'on' permanently..."
      setsebool -P samba_enable_home_dirs on >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        echo "  'samba_enable_home_dirs' set."
      else
        echo "  Warning: Failed to set 'samba_enable_home_dirs'. Check SELinux policy."
      fi

      echo "  Setting SELinux boolean 'samba_export_all_rw' to 'on' permanently..."
      setsebool -P samba_export_all_rw on >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        echo "  'samba_export_all_rw' set."
      else
        echo "  Warning: Failed to set 'samba_export_all_rw'. Check SELinux policy."
      fi

      echo "  SELinux configured for Samba."
    else
      echo "  SELinux is not in Enforcing mode. Skipping SELinux configuration for Samba."
    fi
  else
    echo "  SELinux tools (getenforce, setsebool) not found. Skipping SELinux configuration."
  fi
  echo "-------------------------------------------------------------------"
  sleep 10
}



clear
echo "-------------------------------------------------------------------"
echo "  --- Starting Samba Server Configuration Script ---"
echo "-------------------------------------------------------------------"

check_root
install_samba

echo "-------------------------------------------------------------------"
echo "  This script will help you configure Samba shares on your system."
echo "  A backup of your existing '$SAMBA_CONF' will be created at '$SAMBA_CONF_BACKUP'."
echo "-------------------------------------------------------------------"

# Backup smb.conf
if [ -f "$SAMBA_CONF" ]; then
  echo "  Backing up '$SAMBA_CONF' to '$SAMBA_CONF_BACKUP'..."
  cp "$SAMBA_CONF" "$SAMBA_CONF_BACKUP" || error_exit "Failed to backup Samba configuration."
  echo "  Backup created."
else
  echo "  No existing '$SAMBA_CONF' found. Creating a new one with default guest share..."
  {
    echo "[global]"
    echo "  map to guest = Bad User"
    echo "  log file = /var/log/samba/%m"
    echo "  log level = 1"
    echo "  server role = standalone server"
    echo ""
    echo "[guest]"
    echo "  # This share allows anonymous (guest) access without authentication!"
    echo "  path = ${DEFAULT_GUEST_SHARE_PATH}"
    echo "  read only = no"
    echo "  guest ok = yes"
    echo "  guest only = yes"
  } | tee "$SAMBA_CONF" >/dev/null
  echo "  Created a basic '$SAMBA_CONF' with a default guest share."

  # Create the default guest share directory and set permissions
  echo "  Creating default guest share directory: '$DEFAULT_GUEST_SHARE_PATH'..."
  mkdir -p "$DEFAULT_GUEST_SHARE_PATH" || echo "  Warning: Failed to create default guest share directory."
  chown -R nobody:nobody "$DEFAULT_GUEST_SHARE_PATH" || echo "  Warning: Failed to chown default guest share directory."
  chmod -R 0775 "$DEFAULT_GUEST_SHARE_PATH" || echo "  Warning: Failed to chmod default guest share directory."
  echo "  Default guest share directory created and permissions set."
fi
echo "-------------------------------------------------------------------"


# Loop for adding multiple shares
while true; do
  configure_single_share
  echo "-------------------------------------------------------------------"
  read -rp "  Do you want to add another Samba share? (y/N): " add_another
  add_another=${add_another:-N}
  if [[ ! "$add_another" =~ ^[Yy]$ ]]; then
    echo "  No more shares to add. Exiting share configuration loop."
    break
  fi
done

# Post-Share Configuration
add_samba_users
configure_firewalld
configure_selinux

echo ""
echo "-------------------------------------------------------------------"
echo "  --- Finalizing Samba Configuration ---"
echo "-------------------------------------------------------------------"

# Test Samba configuration
echo "  Testing Samba configuration with 'testparm'..."
testparm -s || {
  echo "  Warning: Samba configuration test failed. Please review '$SAMBA_CONF'."
  echo "  You can try to fix it manually or restore from backup: cp '$SAMBA_CONF_BACKUP' '$SAMBA_CONF'"
}

# Restart Samba service
echo "  Restarting Samba service to apply changes..."
systemctl restart smb nmb || echo "  Warning: Failed to restart Samba services. Please check service status (systemctl status smb nmb)."

echo ""
echo "-------------------------------------------------------------------"
echo "  Samba Configuration Completed!"
echo "  Your Samba server is now configured."
echo "-------------------------------------------------------------------"
echo ""

exit 0
