#!/bin/bash

# Arch Linux Minimal Installation Script with Btrfs, rEFInd, ZRAM, and User Setup
# Version: v1.0.28 - Fixed partition creation and existing partitions display

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  dialog --msgbox "Please run this script as root." 5 40
  exit 1
fi

# Install necessary packages if not already installed
if ! command -v dialog &> /dev/null; then
  pacman -Sy --noconfirm dialog > /dev/null 2>&1
fi
if ! command -v sgdisk &> /dev/null; then
  pacman -Sy --noconfirm gptfdisk > /dev/null 2>&1
fi

# Display script version
dialog --title "Arch Linux Minimal Installer - Version v1.0.28" --msgbox "Welcome to the Arch Linux Minimal Installer script (v1.0.28).

This version fixes issues with partition creation and displays existing partitions before proceeding." 10 70

# Clear the screen
clear

# Check for UEFI mode
if [ ! -d /sys/firmware/efi/efivars ]; then
  dialog --msgbox "Your system is not booted in UEFI mode.
Please reboot in UEFI mode to use this installer." 8 60
  clear
  exit 1
fi

# Check internet connection
if ! ping -c 1 archlinux.org &> /dev/null; then
  dialog --msgbox "Internet connection is required.
Please connect to the internet and rerun the installer." 7 60
  clear
  exit 1
fi

# Set time synchronization
timedatectl set-ntp true

# Welcome message with extended information
dialog --title "Arch Linux Minimal Installer" --msgbox "Welcome to the Arch Linux Minimal Installer.

This installer provides a quick and easy minimal install for Arch Linux, setting up a base system that boots to a terminal." 12 70

# Ask if the user wants to use the default Btrfs subvolume scheme
dialog --yesno "The default Btrfs subvolume scheme is as follows:

@ mounted at /
@home mounted at /home
@pkg mounted at /var/cache/pacman/pkg
@log mounted at /var/log
@snapshots mounted at /.snapshots

Would you like to use this scheme?" 15 70
if [ $? -ne 0 ]; then
  dialog --msgbox "Installation canceled. Exiting." 5 40
  clear
  exit 1
fi

# Disk selection
disk=$(dialog --stdout --title "Select Disk" --menu "Select the disk to install Arch Linux on:" 15 60 4 $(lsblk -dn -o NAME,SIZE | awk '{print "/dev/" $1, "(" $2 ")"}'))
if [ -z "$disk" ]; then
  dialog --msgbox "No disk selected. Exiting." 5 40
  clear
  exit 1
fi

# Detect existing partitions
existing_partitions=$(lsblk -ln -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE "$disk" | grep -E "^[^ ]+ +[^ ]+ +part")
if [ -n "$existing_partitions" ]; then
  # Display existing partitions
  dialog --title "Existing Partitions on $disk" --msgbox "The following partitions were found on $disk:

$existing_partitions" 20 70

  # Ask user whether to destroy partitions
  dialog --yesno "Existing partitions detected on $disk.

Would you like to destroy all partitions on $disk and continue with the installation?

Select 'No' to cancel the installation." 15 70
  if [ $? -eq 0 ]; then
    # Destroy existing partitions
    dialog --infobox "Destroying existing partitions on $disk..." 5 50
    if ! sgdisk --zap-all "$disk" > /tmp/sgdisk_zap_output 2>&1; then
      dialog --msgbox "Failed to destroy partitions on $disk. Error: $(cat /tmp/sgdisk_zap_output)" 10 60
      exit 1
    fi
  else
    dialog --msgbox "Installation canceled by user. Exiting." 5 50
    clear
    exit 1
  fi
fi

# Get partition names (after partitions are created)
if [[ "$(basename $disk)" == nvme* ]]; then
  esp="${disk}p1"
  root_partition="${disk}p2"
else
  esp="${disk}1"
  root_partition="${disk}2"
fi

# Prompt for hostname
hostname=$(dialog --stdout --inputbox "Enter a hostname for your system:" 8 40)
if [ -z "$hostname" ]; then
  dialog --msgbox "No hostname entered. Using default 'archlinux'." 6 50
  hostname="archlinux"
fi

# Prompt for timezone using dialog
available_regions=$(ls /usr/share/zoneinfo | grep -v 'posix\|right\|Etc\|SystemV\|Factory')
region=$(dialog --stdout --title "Select Region" --menu "Select your region:" 20 60 15 $(echo "$available_regions" | awk '{print $1, $1}'))
if [ -z "$region" ]; then
  dialog --msgbox "No region selected. Using 'UTC' as default." 6 50
  timezone="UTC"
else
  available_cities=$(ls /usr/share/zoneinfo/$region)
  city=$(dialog --stdout --title "Select City" --menu "Select your city:" 20 60 15 $(echo "$available_cities" | awk '{print $1, $1}'))
  if [ -z "$city" ]; then
    dialog --msgbox "No city selected. Using 'UTC' as default." 6 50
    timezone="UTC"
  else
    timezone="$region/$city"
  fi
fi

# Prompt for locale selection
available_locales=$(awk '/^[a-z]/ {print $1}' /usr/share/i18n/SUPPORTED | sort)
locale_options=()
index=1
while IFS= read -r line; do
  locale_options+=("$index" "$line")
  index=$((index + 1))
done <<< "$available_locales"

selected_number=$(dialog --stdout --title "Select Locale" --menu "Select your locale:" 20 60 15 "${locale_options[@]}")
if [ -z "$selected_number" ]; then
  dialog --msgbox "No locale selected. Using 'en_US.UTF-8' as default." 6 50
  selected_locale="en_US.UTF-8"
else
  selected_locale=$(echo "$available_locales" | sed -n "${selected_number}p")
fi

# Prompt for root password with validation
while true; do
  root_password=$(dialog --stdout --insecure --passwordbox "Enter a root password (minimum 6 characters):" 10 50)
  if [ -z "$root_password" ]; then
    dialog --msgbox "Password cannot be empty. Please try again." 6 50
    continue
  elif [ ${#root_password} -lt 6 ]; then
    dialog --msgbox "Password must be at least 6 characters long. Please try again." 6 60
    continue
  fi
  root_password_confirm=$(dialog --stdout --insecure --passwordbox "Confirm the root password:" 8 50)
  if [ "$root_password" != "$root_password_confirm" ]; then
    dialog --msgbox "Passwords do not match. Please try again." 6 50
  else
    break
  fi
done

# Prompt to create a new user account
dialog --yesno "Would you like to create a new user account?" 7 50
if [ $? -eq 0 ]; then
  create_user="yes"
  # Prompt for username
  while true; do
    username=$(dialog --stdout --inputbox "Enter the username for the new account:" 8 40)
    if [ -z "$username" ]; then
      dialog --msgbox "Username cannot be empty. Please try again." 6 50
    else
      break
    fi
  done

  # Prompt for user password with validation
  while true; do
    user_password=$(dialog --stdout --insecure --passwordbox "Enter a password for $username (minimum 6 characters):" 10 50)
    if [ -z "$user_password" ]; then
      dialog --msgbox "Password cannot be empty. Please try again." 6 50
      continue
    elif [ ${#user_password} -lt 6 ]; then
      dialog --msgbox "Password must be at least 6 characters long. Please try again." 6 60
      continue
    fi
    user_password_confirm=$(dialog --stdout --insecure --passwordbox "Confirm the password for $username:" 8 50)
    if [ "$user_password" != "$user_password_confirm" ]; then
      dialog --msgbox "Passwords do not match. Please try again." 6 50
    else
      break
    fi
  done

  # Prompt to grant sudo privileges
  dialog --yesno "Should the user '$username' have sudo privileges?" 7 50
  if [ $? -eq 0 ]; then
    grant_sudo="yes"
  else
    grant_sudo="no"
  fi
else
  create_user="no"
fi

# Combine optional features into a single selection dialog with descriptive tags
options=(
  "btrfs" "Install btrfs-progs" off
  "networkmanager" "Install NetworkManager" off
  "zram" "Enable ZRAM" off
)
selected_options=$(dialog --stdout --separate-output --checklist "Select optional features (use spacebar to select):" 15 60 4 "${options[@]}")
if [ -z "$selected_options" ]; then
  dialog --msgbox "No optional features selected." 5 40
fi

# Initialize variables
btrfs_pkg=""
networkmanager_pkg=""
zram_pkg=""

# Process selected options without subshell
while IFS= read -r opt; do
  case "$opt" in
    btrfs)
      btrfs_pkg="btrfs-progs"
      ;;
    networkmanager)
      networkmanager_pkg="networkmanager"
      ;;
    zram)
      zram_pkg="zram-generator"
      ;;
  esac
done <<< "$selected_options"

# Trim any whitespace (just in case)
btrfs_pkg=$(echo "$btrfs_pkg" | xargs)
networkmanager_pkg=$(echo "$networkmanager_pkg" | xargs)
zram_pkg=$(echo "$zram_pkg" | xargs)

# Detect CPU and offer to install microcode
cpu_vendor=$(grep -m1 -E 'vendor_id|Vendor ID' /proc/cpuinfo | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
microcode_pkg=""
microcode_img=""

if [[ "$cpu_vendor" == *"intel"* ]]; then
  dialog --yesno "CPU detected: Intel
Would you like to install intel-ucode?" 7 60
  if [ $? -eq 0 ]; then
    microcode_pkg="intel-ucode"
    microcode_img="intel-ucode.img"
  fi
elif [[ "$cpu_vendor" == *"amd"* ]]; then
  dialog --yesno "CPU detected: AMD
Would you like to install amd-ucode?" 7 60
  if [ $? -eq 0 ]; then
    microcode_pkg="amd-ucode"
    microcode_img="amd-ucode.img"
  fi
else
  dialog --msgbox "CPU vendor not detected. Microcode will not be installed." 6 60
fi

# All dialogs are now completed before installation starts

# Create partitions
dialog --infobox "Creating partitions on $disk..." 5 50
# Partition 1: EFI System Partition
if ! sgdisk -n 1:0:+300M -t 1:ef00 "$disk" > /tmp/sgdisk_efi_output 2>&1; then
  dialog --msgbox "Failed to create EFI partition on $disk. Error: $(cat /tmp/sgdisk_efi_output)" 10 60
  exit 1
fi

# Wait for the system to recognize the partition changes
sleep 2

# Partition 2: Root partition
if ! sgdisk -n 2:0:0 -t 2:8300 "$disk" > /tmp/sgdisk_root_output 2>&1; then
  dialog --msgbox "Failed to create root partition on $disk. Error: $(cat /tmp/sgdisk_root_output)" 10 60
  exit 1
fi

# Wait for the system to recognize the partition changes
sleep 2

# Clean up temporary files
rm -f /tmp/sgdisk_zap_output /tmp/sgdisk_efi_output /tmp/sgdisk_root_output

# Format partitions
dialog --infobox "Formatting partitions..." 5 50
mkfs.vfat -F32 -n EFI "$esp" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  dialog --msgbox "Failed to format EFI partition. Exiting." 5 40
  exit 1
fi
mkfs.btrfs -f -L Arch "$root_partition" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  dialog --msgbox "Failed to format root partition. Exiting." 5 40
  exit 1
fi

# Mount root partition
dialog --infobox "Mounting root partition..." 5 50
mount "$root_partition" /mnt
if [ $? -ne 0 ]; then
  dialog --msgbox "Failed to mount root partition. Exiting." 5 40
  exit 1
fi

# Create Btrfs subvolumes
dialog --infobox "Creating Btrfs subvolumes..." 5 50
btrfs su cr /mnt/@ > /dev/null 2>&1
if [ $? -ne 0 ]; then
  dialog --msgbox "Failed to create @ subvolume. Exiting." 5 40
  exit 1
fi
btrfs su cr /mnt/@home > /dev/null 2>&1
btrfs su cr /mnt/@pkg > /dev/null 2>&1
btrfs su cr /mnt/@log > /dev/null 2>&1
btrfs su cr /mnt/@snapshots > /dev/null 2>&1

# Unmount root partition
umount /mnt

# Mount subvolumes with options
mount_options="noatime,compress=zstd,discard=async,space_cache=v2"
dialog --infobox "Mounting Btrfs subvolumes..." 5 50
mount -o $mount_options,subvol=@ "$root_partition" /mnt
if [ $? -ne 0 ]; then
  dialog --msgbox "Failed to mount root subvolume. Exiting." 5 40
  exit 1
fi
mkdir -p /mnt/{efi,home,var/cache/pacman/pkg,var/log,.snapshots}
mount -o $mount_options,subvol=@home "$root_partition" /mnt/home
mount -o $mount_options,subvol=@pkg "$root_partition" /mnt/var/cache/pacman/pkg
mount -o $mount_options,subvol=@log "$root_partition" /mnt/var/log
mount -o $mount_options,subvol=@snapshots "$root_partition" /mnt/.snapshots

# Mount EFI partition at /mnt/efi before chrooting
dialog --infobox "Mounting EFI partition at /mnt/efi..." 5 50
mount "$esp" /mnt/efi
if [ $? -ne 0 ]; then
  dialog --msgbox "Failed to mount EFI partition. Exiting." 5 40
  exit 1
fi

# Construct the packages array
# Initialize the packages array with mandatory packages
packages=(base linux linux-firmware)

# Append optional packages if selected
[ -n "$microcode_pkg" ] && packages+=("$microcode_pkg")
[ -n "$btrfs_pkg" ] && packages+=("$btrfs_pkg")
[ -n "$zram_pkg" ] && packages+=("$zram_pkg")
[ -n "$networkmanager_pkg" ] && packages+=("$networkmanager_pkg")

# Install base system with enhanced progress feedback

# Step 1: Updating package databases
dialog --infobox "Updating package databases..." 5 50
pacman -Syy --noconfirm > /dev/null 2>&1
if [ $? -ne 0 ]; then
  dialog --msgbox "Failed to update package databases. Exiting." 5 40
  exit 1
fi

# Step 2: Downloading packages
dialog --title "Downloading Packages" --gauge "Downloading packages...
This may take a while." 10 70 0 < <(
  total_packages=$(pacman -Sp --needed --noconfirm "${packages[@]}" 2>/dev/null | wc -l)
  pacman -Sw --noconfirm --needed "${packages[@]}" > /tmp/pacman_download.log 2>&1 &
  pid=$!
  downloaded_packages=0
  while kill -0 $pid 2> /dev/null; do
    sleep 1
    downloaded_packages=$(grep -c "downloading" /tmp/pacman_download.log)
    percent=$(( (downloaded_packages * 100) / total_packages ))
    echo $percent
  done
  wait $pid
  echo 100
)
if [ $? -ne 0 ]; then
  dialog --msgbox "Failed to download packages. Exiting." 5 40
  exit 1
fi

# Step 3: Installing base system
dialog --title "Installing Base System" --gauge "Installing base system...
This may take a while." 10 70 0 < <(
  total_packages=$(pacman -Qq --cachedir /var/cache/pacman/pkg "${packages[@]}" 2>/dev/null | wc -l)
  pacstrap /mnt "${packages[@]}" > /tmp/pacman_install.log 2>&1 &
  pid=$!
  installed_packages=0
  while kill -0 $pid 2> /dev/null; do
    sleep 1
    installed_packages=$(grep -c "installing" /tmp/pacman_install.log)
    percent=$(( (installed_packages * 100) / total_packages ))
    echo $percent
  done
  wait $pid
  echo 100
)
if [ $? -ne 0 ]; then
  dialog --msgbox "Failed to install base system. Exiting." 5 40
  exit 1
fi

# Clean up temporary logs
rm /tmp/pacman_download.log /tmp/pacman_install.log

# Generate fstab
dialog --infobox "Generating fstab..." 5 50
genfstab -U /mnt >> /mnt/etc/fstab
if [ $? -ne 0 ]; then
  dialog --msgbox "Failed to generate fstab. Exiting." 5 40
  exit 1
fi

# Set up variables for chroot
export esp  # Ensure esp is exported for use inside the chroot
export root_partition
export microcode_img
export hostname
export timezone
export selected_locale
export zram_pkg
export root_password
export create_user
export username
export user_password
export grant_sudo

# Mount necessary filesystems before chrooting
for dir in dev proc sys run; do
  mount --rbind "/$dir" "/mnt/$dir"
done

# Chroot into the new system for configurations
arch-chroot /mnt /bin/bash <<EOF_VAR
# Suppress command outputs inside chroot
exec > /dev/null 2>&1

# Set the timezone
ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
hwclock --systohc

# Set the hostname
echo "$hostname" > /etc/hostname

# Configure /etc/hosts
cat <<EOL > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain $hostname
EOL

# Generate locales
echo "$selected_locale UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$selected_locale" > /etc/locale.conf

# Configure ZRAM if enabled
if [ -n "$zram_pkg" ]; then
  cat <<EOM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOM
fi

# Set the root password
echo "root:$root_password" | chpasswd

# Clear the root password variable for security
unset root_password

# Create user account if requested
if [ "$create_user" == "yes" ]; then
  useradd -m "$username"
  echo "$username:$user_password" | chpasswd
  unset user_password

  if [ "$grant_sudo" == "yes" ]; then
    pacman -Sy --noconfirm sudo > /dev/null 2>&1
    usermod -aG wheel "$username"
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
  fi
fi

# Install rEFInd bootloader with --no-mount option
pacman -Sy --noconfirm refind > /dev/null 2>&1
refind-install --yes --no-mount > /dev/null 2>&1

if [ \$? -ne 0 ]; then
  echo "Failed to install rEFInd. Exiting."
  exit 1
fi

# rEFInd configuration
sed -i 's/^#enable_mouse/enable_mouse/' /efi/EFI/refind/refind.conf
sed -i 's/^#mouse_speed .*/mouse_speed 8/' /efi/EFI/refind/refind.conf
sed -i 's/^#resolution .*/resolution max/' /efi/EFI/refind/refind.conf
sed -i 's/^#extra_kernel_version_strings .*/extra_kernel_version_strings linux-hardened,linux-rt-lts,linux-zen,linux-lts,linux-rt,linux/' /efi/EFI/refind/refind.conf

# Create refind_linux.conf with the specified options
partuuid=\$(blkid -s PARTUUID -o value $root_partition)
initrd_line=""
if [ -n "$microcode_img" ]; then
  initrd_line="initrd=\\@\\boot\\$microcode_img initrd=\\@\\boot\\initramfs-%v.img"
else
  initrd_line="initrd=\\@\\boot\\initramfs-%v.img"
fi

cat << EOF > /boot/refind_linux.conf
"Boot with standard options"  "root=PARTUUID=\$partuuid rw rootflags=subvol=@ \$initrd_line"
"Boot using fallback initramfs"  "root=PARTUUID=\$partuuid rw rootflags=subvol=@ initrd=\\@\\boot\\initramfs-%v-fallback.img"
"Boot to terminal"  "root=PARTUUID=\$partuuid rw rootflags=subvol=@ \$initrd_line systemd.unit=multi-user.target"
EOF

# Ask if the user wants to use bash or install zsh
if [ -f /bin/dialog ]; then
  pacman -Sy --noconfirm dialog > /dev/null 2>&1
  dialog --yesno "Would you like to use Zsh as your default shell instead of Bash?" 7 50
  if [ \$? -eq 0 ]; then
    pacman -Sy --noconfirm zsh > /dev/null 2>&1
    chsh -s /bin/zsh
    if [ "$create_user" == "yes" ]; then
      chsh -s /bin/zsh "$username"
    fi
  fi
fi

EOF_VAR

# Unmount the filesystems after chrooting
for dir in dev proc sys run; do
  umount -l "/mnt/$dir"
done

# Clear sensitive variables
unset root_password
unset user_password

# Finish installation
dialog --yesno "Installation complete! Would you like to reboot now or drop to the terminal for additional configuration?

Select 'No' to drop to the terminal." 10 70
if [ $? -eq 0 ]; then
  # Reboot the system
  umount -R /mnt
  reboot
else
  # Clear the screen
  clear
  # Bind mount necessary filesystems for chroot
  for dir in dev proc sys run; do
    mount --rbind "/$dir" "/mnt/$dir"
  done

  # Drop into the chroot environment
  echo "Type 'exit' to leave the chroot environment and complete the installation."
  sleep 2

  # Redirect stdin and stdout to the terminal
  arch-chroot /mnt /bin/bash < /dev/tty > /dev/tty 2>&1

  # After exiting chroot, unmount filesystems
  for dir in dev proc sys run; do
    umount -l "/mnt/$dir"
  done
  umount -R /mnt
fi
