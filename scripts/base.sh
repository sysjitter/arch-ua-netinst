#!/usr/bin/env bash
set -e -u
echo 'Mirror selection'
curl "https://www.archlinux.org/mirrorlist/?country=US&protocol=https&ip_version=4&ip_version=6&use_mirror_status=on" | sed 's/#Server/Server/g' > /etc/pacman.d/mirrorlist

echo 'Partition drive.'
parted -s /dev/sda mklabel gpt
parted -s --align optimal /dev/sda mkpart ESP fat32 1MiB 100MiB
parted -s /dev/sda name 1 ESP
parted -s /dev/sda set 1 boot
parted -s --align optimal /dev/sda mkpart root btrfs 101MiB 100%
parted -s /dev/sda name 2 root

echo 'Make filesystems.'
mkfs.vfat -n ESP -F 32 /dev/sda1
mkfs.btrfs -f -L root /dev/sda2

echo 'Mount virtual drives'
mount /dev/sda2 /mnt
mkdir -p /mnt/boot
mount /dev/sda1 /mnt/boot

echo 'Bootstrap the base system'
pacstrap /mnt

echo 'Generate an fstab'
genfstab -U -p /mnt >> /mnt/etc/fstab

/bin/arch-chroot /mnt /bin/bash <<SCRIPT

echo 'Setting locale information'

sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf

echo 'Set the HW Clock'
hwclock --systohc --utc

echo 'Enable systemd-networkd'
systemctl enable systemd-networkd

echo 'Enable systemd-resolved'
systemctl enable systemd-resolved
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
sed -i 's/dns/resolve/' /etc/nsswitch.conf

echo 'Enable DHCP on all network interfaces'
cat <<CONF>/etc/systemd/network/wired.network
[Network]
DHCP=yes
CONF

echo 'Update and refresh Arch keyrings'
pacman-key --init
pacman-key --populate archlinux
pacman-key --refresh-keys
sed -i 's/#RemoteFileSigLevel = Required/RemoteFileSigLevel = Required/' /etc/pacman.conf

echo 'Create vagrant user'
useradd -m -G wheel vagrant
mkdir -p /home/vagrant/.ssh
touch /home/vagrant/.ssh/authorized_keys

echo 'Fix permissions on vagrant keys.'
chown -R vagrant /home/vagrant/
chmod 700 /home/vagrant/.ssh/
chmod 600 /home/vagrant/.ssh/authorized_keys

echo 'Add wheel group to the sudoers list'
pacman -S --noconfirm --needed sudo
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel

echo 'Ensure ssh is installed'
pacman -S --noconfirm --needed openssh
systemctl enable sshd.service

echo 'Ensure haveged is installed'
pacman -S --noconfirm --needed haveged
systemctl enable haveged.service

echo 'Ensure btrfs is installed'
pacman -S --noconfirm --needed btrfs-progs

echo 'Ensure Intel microcode is installed'
pacman -S --noconfirm --needed intel-ucode

echo 'Set up the virtualbox guest additions'
pacman -S --noconfirm --needed linux-headers virtualbox-guest-utils-nox

mkdir -p /etc/modules-load.d
cat <<CONF>/etc/modules-load.d/virtualbox.conf
vboxguest
vboxsf
vboxvideo
CONF

echo 'EFI boot using systemd-boot'
bootctl --path=/boot install

echo 'default arch' >> /boot/loader/loader.conf
cat <<CONF>/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=PARTUUID=$(blkid /dev/sda2 -s PARTUUID | cut -d\" -f2) rw
CONF
SCRIPT
