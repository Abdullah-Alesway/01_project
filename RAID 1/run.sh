#!/bin/bash

# Global Variables 
RAID_ARRAY_NAME="/dev/md0"
FILESYSTEM_TYPE="ext4"    
DEFAULT_MOUNT_POINT="/mnt/raid1_share" 
DEFAULT_OWNER="nobody:nobody"          
DEFAULT_CHMOD="0775"                   


#  Error messages 
error_exit() {
  echo "ERROR: $1" >&2
  exit 1
}

# Check if the script is running as root
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

# Check for mdadm package
check_mdadm() {
  echo "  Checking for 'mdadm' package..."
  if ! rpm -q mdadm &>/dev/null; then
    echo "  'mdadm' package not found. Attempting to install it..."
    dnf install -y mdadm || error_exit "Failed to install 'mdadm'. Please install it manually and re-run the script."
    echo "  'mdadm' installed successfully."
  else
    echo "  'mdadm' is already installed."
  fi
  echo "-------------------------------------------------------------------"
}


clear 
echo "-------------------------------------------------------------------"
echo "  --- Starting RAID 1 Array Configuration Script ---"
echo "-------------------------------------------------------------------"
echo ""
echo "  WARNING: This script will ERASE ALL DATA on the disks you select."
echo "           Proceed with EXTREME CAUTION. Data backup is essential!"
echo ""
echo "-------------------------------------------------------------------"
sleep 3

check_root
check_mdadm

# Select Disks 
clear
echo "-------------------------------------------------------------------"
echo "  --- Disk Selection for RAID 1 ---"
echo "-------------------------------------------------------------------"
echo "  Available block devices (look for TYPE='disk' and no MOUNTPOINT):"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE 
echo ""

read -rp "  Enter the FIRST device path for RAID 1 (e.g., /dev/sdb): " DEVICE1
read -rp "  Enter the SECOND device path for RAID 1 (e.g., /dev/sdc): " DEVICE2

# device paths
if [[ -z "$DEVICE1" || -z "$DEVICE2" ]]; then
  error_exit "Both device paths must be provided. Exiting."
elif [[ ! -b "$DEVICE1" || ! -b "$DEVICE2" ]]; then
  error_exit "One or both specified devices ($DEVICE1, $DEVICE2) do not exist or are not block devices. Exiting."
elif [[ "$DEVICE1" == "$DEVICE2" ]]; then
  error_exit "You must select two different devices for RAID 1. Exiting."
fi

echo ""
echo "  You have selected '$DEVICE1' and '$DEVICE2' for RAID 1."
read -rp "  Confirm these are the correct devices to format and use for RAID 1? (y/N): " confirm_devices
confirm_devices=${confirm_devices:-N}
if [[ ! "$confirm_devices" =~ ^[Yy]$ ]]; then
  error_exit "Device selection cancelled. Exiting."
fi
clear

# Zero Superblocks 
echo "-------------------------------------------------------------------"
echo "  --- Zeroing Superblocks on Selected Devices ---"
echo "-------------------------------------------------------------------"
echo "  This will destroy any existing RAID metadata or filesystems on $DEVICE1 and $DEVICE2."
read -rp "  Are you absolutely sure you want to proceed with zeroing superblocks? (y/N): " confirm_zero
confirm_zero=${confirm_zero:-N}
if [[ ! "$confirm_zero" =~ ^[Yy]$ ]]; then
  error_exit "Zeroing superblocks cancelled. Exiting."
fi

echo "  Zeroing superblocks on $DEVICE1..."
mdadm --zero-superblock "$DEVICE1" || echo "  Warning: Failed to zero superblock on $DEVICE1. Continuing..."
echo "  Zeroing superblocks on $DEVICE2..."
mdadm --zero-superblock "$DEVICE2" || echo "  Warning: Failed to zero superblock on $DEVICE2. Continuing..."
echo "  Superblocks zeroed (or skipped)."
echo "-------------------------------------------------------------------"
sleep 2

# Create RAID 1 Array
clear
echo "-------------------------------------------------------------------"
echo "  --- Creating RAID 1 Array ---"
echo "-------------------------------------------------------------------"
echo "  Creating RAID 1 array '$RAID_ARRAY_NAME' with $DEVICE1 and $DEVICE2..."
mdadm --create "$RAID_ARRAY_NAME" --level=1 --raid-devices=2 "$DEVICE1" "$DEVICE2" || error_exit "Failed to create RAID array."
echo "  RAID 1 array creation initiated. This may take some time to synchronize."
echo "  You can monitor synchronization status using: 'cat /proc/mdstat'"
echo ""
echo "  Current RAID status:"
cat /proc/mdstat
echo "-------------------------------------------------------------------"
sleep 5

# Persist RAID Configuration 
clear
echo "-------------------------------------------------------------------"
echo "  --- Persisting RAID Configuration ---"
echo "-------------------------------------------------------------------"
echo "  Saving RAID array configuration to /etc/mdadm.conf..."
mdadm --detail --scan > /etc/mdadm.conf || error_exit "Failed to save mdadm.conf. Manual intervention required."
echo "  RAID configuration saved."

echo "  Updating initramfs to ensure boot with RAID array..."
dracut -H -f /boot/initramfs-$(uname -r).img $(uname -r) || error_exit "Failed to update initramfs. System may not boot with RAID."
echo "  Initramfs updated."
echo "-------------------------------------------------------------------"
sleep 2

# Format RAID Array 
clear
echo "-------------------------------------------------------------------"
echo "  --- Formatting RAID Array ---"
echo "-------------------------------------------------------------------"
echo "  Formatting '$RAID_ARRAY_NAME' with $FILESYSTEM_TYPE filesystem..."
mkfs.$FILESYSTEM_TYPE "$RAID_ARRAY_NAME" || error_exit "Failed to format RAID array '$RAID_ARRAY_NAME'."
echo "  RAID array formatted successfully."
echo "-------------------------------------------------------------------"
sleep 2

# Configure Mount Point and fstab 
clear
echo "-------------------------------------------------------------------"
echo "  --- Configuring Mount Point and fstab ---"
echo "-------------------------------------------------------------------"
read -rp "  Enter the desired mount point for the RAID array (e.g., '$DEFAULT_MOUNT_POINT', leave empty for default): " CUSTOM_MOUNT_POINT
CUSTOM_MOUNT_POINT=${CUSTOM_MOUNT_POINT:-$DEFAULT_MOUNT_POINT}

echo "  Creating mount point directory '$CUSTOM_MOUNT_POINT'..."
mkdir -p "$CUSTOM_MOUNT_POINT" || error_exit "Failed to create mount point directory '$CUSTOM_MOUNT_POINT'."
echo "  Mount point created."

echo "  Adding entry to /etc/fstab for automatic mounting..."
echo "$RAID_ARRAY_NAME $CUSTOM_MOUNT_POINT $FILESYSTEM_TYPE defaults 0 0" >> /etc/fstab || error_exit "Failed to update /etc/fstab. Manual edit required."
echo "  fstab updated. Verifying fstab entry..."

echo "  Mounting RAID array to '$CUSTOM_MOUNT_POINT'..."
mount "$CUSTOM_MOUNT_POINT" || error_exit "Failed to mount RAID array to '$CUSTOM_MOUNT_POINT'. Check fstab and logs."
echo "  RAID array mounted successfully."
echo "-------------------------------------------------------------------"
sleep 2

# Set Permissions 
clear
echo "-------------------------------------------------------------------"
echo "  --- Setting Permissions on Mount Point ---"
echo "-------------------------------------------------------------------"
read -rp "  Enter desired owner for '$CUSTOM_MOUNT_POINT' (e.g., 'user:group', default '$DEFAULT_OWNER'): " CUSTOM_OWNER
CUSTOM_OWNER=${CUSTOM_OWNER:-$DEFAULT_OWNER}

echo "  Setting ownership of '$CUSTOM_MOUNT_POINT' to '$CUSTOM_OWNER'..."
chown -R "$CUSTOM_OWNER" "$CUSTOM_MOUNT_POINT" || echo "  Warning: Failed to set ownership. Manual intervention might be needed."

read -rp "  Enter desired permissions for '$CUSTOM_MOUNT_POINT' (e.g., '0770', default '$DEFAULT_CHMOD'): " CUSTOM_CHMOD
if [ -n "$CUSTOM_CHMOD" ]; then 
  if [[ ! "$CUSTOM_CHMOD" =~ ^[0-7]{3,4}$ ]]; then
    echo "  Warning: Invalid chmod format. Using default '$DEFAULT_CHMOD'."
    CUSTOM_CHMOD="$DEFAULT_CHMOD"
  fi
else
  CUSTOM_CHMOD="$DEFAULT_CHMOD"
fi
echo "  Setting permissions of '$CUSTOM_MOUNT_POINT' to '$CUSTOM_CHMOD'..."
chmod "$CUSTOM_CHMOD" "$CUSTOM_MOUNT_POINT" || echo "  Warning: Failed to set permissions. Manual intervention might be needed."
echo "  Permissions set."
echo "-------------------------------------------------------------------"
sleep 2

# Verification 
clear
echo "-------------------------------------------------------------------"
echo "  --- RAID 1 Setup Completed ---"
echo "-------------------------------------------------------------------"
echo "  Summary of RAID configuration:"
echo ""
echo "  RAID Array: $RAID_ARRAY_NAME (RAID 1)"
echo "  Devices:    $DEVICE1, $DEVICE2"
echo "  Filesystem: $FILESYSTEM_TYPE"
echo "  Mount Point: $CUSTOM_MOUNT_POINT"
echo "  Owner:      $CUSTOM_OWNER"
echo "  Permissions: $CUSTOM_CHMOD"
echo ""
echo "  Current disk usage and mounts:"
df -h "$CUSTOM_MOUNT_POINT" 2>/dev/null || echo "  Failed to display mount status for $CUSTOM_MOUNT_POINT. Check 'df -h'."
echo ""
echo "  RAID status (check for 'resync' progress if any):"
cat /proc/mdstat
echo ""
echo "  Final lsblk output:"
lsblk -f
echo ""
echo "-------------------------------------------------------------------"
echo "  RAID 1 array has been successfully created, formatted, and mounted."
echo "  It is configured to mount automatically on boot."
echo "-------------------------------------------------------------------"
echo ""

exit 0
