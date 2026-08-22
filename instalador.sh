bash#!/usr/bin/env bash

# Detener el script si ocurre algún error
set -e

echo "=== Iniciando Instalación de Arch Linux (ArchLancache) ==="

# 1. Configurar reloj del sistema
timedatectl set-ntp true

# 2. Particionado de disco automático (Ejemplo usando /dev/sda)
# NOTA: Modifica el disco objetivo según tus necesidades
DISCO="/dev/sda"
echo "Formateando disco $DISCO..."

# Crear tabla de particiones GPT
parted -s "$DISCO" mklabel gpt
parted -s "$DISCO" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISCO" set 1 boot on
parted -s "$DISCO" mkpart primary ext4 513MiB 100%

# Formatear particiones
mkfs.vfat -F32 "${DISCO}1"
mkfs.ext4 -F -F "${DISCO}2"

# Montar sistemas de archivos
mount "${DISCO}2" /mnt
mkdir -p /mnt/boot
mount "${DISCO}1" /mnt/boot

# 3. Instalar paquetes esenciales (incluye sudo para el usuario inhumano)
pacstrap /mnt base base-devel linux linux-firmware nano grub efibootmgr networkmanager sudo

# 4. Generar FSTAB
genfstab -U /mnt >> /mnt/etc/fstab

# 5. Configuración dentro del CHROOT
cat <<EOF > /mnt/root/chroot_setup.sh
#!/bin/bash
set -e

# Configurar zona horaria (Modifica según tu ubicación)
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock --systohc

# Configurar idioma
echo "es_ES.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=es_ES.UTF-8" > /etc/locale.conf
echo "KEYMAP=es" > /etc/vconsole.conf

# Configurar nombre de equipo (Hostname)
echo "ArchLancache" > /etc/hostname
cat <<EOT >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.0.1   ArchLancache.localdomain ArchLancache
EOT

# Configurar contraseña de root
echo "root:Pacopicopoco.7" | chpasswd

# Crear usuario inhumano, asignarle grupo wheel y configurar su contraseña
useradd -m -g users -G wheel -s /bin/bash inhumano
echo "inhumano:Pacopicopoco.7" | chpasswd

# Permitir a los miembros del grupo wheel usar sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# Habilitar servicios de red
systemctl enable NetworkManager

# Instalar y configurar el cargador de arranque GRUB (Modo UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

EOF

# Ejecutar el script secundario dentro de chroot
chmod +x /mnt/root/chroot_setup.sh
arch-chroot /mnt /root/chroot_setup.sh

# Limpieza del script temporal
rm /mnt/root/chroot_setup.sh

# 6. Desmontar y finalizar
umount -R /mnt
echo "=== Instalación completada con éxito. Puedes reiniciar el equipo. ==="
