#!/usr/bin/env bash
set -e -u

echo "Enable NTP"
timedatectl set-ntp true

echo "Mirror selection"
curl -q "https://www.archlinux.org/mirrorlist/?country=US&protocol=https&ip_version=4&ip_version=6&use_mirror_status=on" | sed 's/#Server/Server/g' > /etc/pacman.d/mirrorlist

echo "Partition drive"
parted -s /dev/sda mklabel gpt
parted -s --align optimal /dev/sda mkpart ESP fat32 1MiB 100MiB
parted -s /dev/sda name 1 ESP
parted -s /dev/sda set 1 boot
parted -s --align optimal /dev/sda mkpart root btrfs 101MiB 100%
parted -s /dev/sda name 2 root

echo "Make filesystems"
mkfs.vfat -n ESP -F 32 /dev/sda1
mkfs.btrfs -f -L root /dev/sda2
sync

echo "Create top-level BTRFS subvolumes"
boot_partuuid="$(lsblk -rno PARTUUID /dev/sda1)"
root_partuuid="$(lsblk -rno PARTUUID /dev/sda2)"

boot_part="/dev/disk/by-partuuid/${boot_partuuid}"
root_part="/dev/disk/by-partuuid/${root_partuuid}"

mount -o defaults,noatime,compress=lzo,autodefrag ${root_part} /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount -R /mnt

echo "Mount subvolumes appropriately for installation"
mount -o defaults,noatime,compress=lzo,autodefrag,subvol=@ ${root_part} /mnt
mkdir -p /mnt/{boot,home,.snapshots,srv,var/cache/pacman}
mount -o defaults,noatime ${boot_part} /mnt/boot
mount -o defaults,noatime,compress=lzo,autodefrag,subvol=@srv ${root_part} /mnt/srv
mount -o defaults,noatime,compress=lzo,autodefrag,subvol=@home ${root_part} /mnt/home
mount -o defaults,noatime,compress=lzo,autodefrag,subvol=@snapshots ${root_part} /mnt/.snapshots
btrfs subvolume create /mnt/var/abs
btrfs subvolume create /mnt/var/log
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/var/cache/pacman/pkg
chmod 1777 /mnt/var/tmp

echo 'Bootstrap the base system'
pacstrap /mnt

echo 'Generate an fstab of the final filesystem layout'
genfstab -U -p /mnt >> /mnt/etc/fstab

echo 'Configure systemd-resolved outside of arch-chroot'
systemctl start systemd-resolved
ln -sf /run/systemd/resolve/resolv.conf /mnt/etc/resolv.conf

/bin/arch-chroot /mnt /bin/bash <<SCRIPT

echo 'Setting locale information'

sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf

echo 'Set the HW Clock'
hwclock --systohc --utc

echo 'Enable systemd-networkd and systemd-resolved for simple network configuration'
systemctl enable systemd-networkd systemd-resolved

echo 'Enable DHCP on all network interfaces'
cat <<CONF>/etc/systemd/network/wired.network
[Network]
DHCP=yes
CONF

echo 'Use BTRFS subvolume for snapshots instead of Snapper defaults'
pacman -S --noconfirm --needed --noprogressbar btrfs-progs snapper
cp /etc/snapper/config-templates/default /etc/snapper/configs/root
sed -i 's/SNAPPER_CONFIGS=""/SNAPPER_CONFIGS="root"/' /etc/conf.d/snapper
systemctl enable snapper-boot.timer snapper-timeline.timer snapper-cleanup.timer

echo 'Update and refresh Arch keyrings'
pacman-key --init
pacman-key --populate archlinux
pacman-key --refresh-keys
sed -i 's/#RemoteFileSigLevel = Required/RemoteFileSigLevel = Required/' /etc/pacman.conf

echo 'Create vagrant user'
useradd -m -G wheel vagrant
mkdir -p /home/vagrant/.ssh
touch /home/vagrant/.ssh/authorized_keys

echo 'Fix permissions on vagrant keys'
chown -R vagrant /home/vagrant/
chmod 700 /home/vagrant/.ssh/
chmod 600 /home/vagrant/.ssh/authorized_keys

echo 'Add wheel group to the sudoers list'
pacman -S --noconfirm --needed --noprogressbar sudo
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel

echo 'Ensure ssh is installed for connectivity'
pacman -S --noconfirm --needed --noprogressbar openssh
systemctl enable sshd.service

echo 'Ensure haveged is installed to generate entropy inside a virtual machine'
pacman -S --noconfirm --needed --noprogressbar haveged
systemctl enable haveged.service

echo 'Ensure Intel microcode is installed'
pacman -S --noconfirm --needed --noprogressbar intel-ucode

echo 'Set up the virtualbox guest additions'
pacman -S --noconfirm --needed --noprogressbar linux-headers virtualbox-guest-utils-nox

mkdir -p /etc/modules-load.d
cat <<CONF>/etc/modules-load.d/virtualbox.conf
vboxguest
vboxsf
vboxvideo
CONF

echo 'Configure EFI boot using systemd-boot'
bootctl --path=/boot install

echo 'default arch' >> /boot/loader/loader.conf

cat <<CONF>/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=PARTUUID=${root_partuuid} rw rootflags=subvol=@
CONF

echo 'Enable BTRFS snapshots on pacman actions going forward'
pacman -S --noconfirm --needed --noprogressbar snap-pac
SCRIPT
