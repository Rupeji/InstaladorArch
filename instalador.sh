#!/bin/bash

# Evitar que el script continúe si ocurre cualquier error crítico
set -e

echo "========================================================="
echo " Instalador Todo en Uno: IP Estática + Alias + LanCache + Pi-hole "
echo "========================================================="

# ==========================================
# 0. COMPROBACIÓN DE PRIVILEGIOS
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo "[!] Este script necesita permisos de administrador (root)."
    if command -v sudo >/dev/null 2>&1; then
        echo "[-] Solicitando privilegios mediante sudo..."
        exec sudo "$0" "$@"
    else
        echo "[!] Error: No se detectó 'sudo'. Ejecuta el script directamente como root."
        exit 1
    fi
fi

# ==========================================
# 1. VARIABLES DE CONFIGURACIÓN
# ==========================================
LANCACHE_IP="192.168.0.7"   # IP principal para el servidor y LanCache
PIHOLE_IP="192.168.0.8"     # IP secundaria/virtual asignada a Pi-hole
NETMASK_SHORT="24"          # Máscara /24 (255.255.255.0)
GATEWAY="192.168.0.1"       # IP de tu router
DNS_PROVISIONAL="1.1.1.1"   # DNS externo para descargar los paquetes iniciales
PASSWORD_PIHOLE="TuContraseñaSegura123" # Cambia esto para tu panel de Pi-hole

# ==========================================
# 2. INSTALACIÓN DE DEPENDENCIAS
# ==========================================
echo ""
echo "[-] Actualizando repositorios e instalando paquetes esenciales..."
echo "---------------------------------------------------------"
pacman -Sy --noconfirm
pacman -S --needed --noconfirm git curl util-linux docker docker-compose fastfetch nano openssh

echo "[-] Activando e iniciando servicios de sistema..."
systemctl enable --now docker
systemctl enable --now sshd

# Permitir SSH Root por conveniencia en servidores locales
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
if ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
fi
systemctl restart sshd

# ==========================================
# 3. RED ESTÁTICA + IP VIRTUAL (ALIAS)
# ==========================================
echo ""
echo "[-] Detectando gestor de red activo..."
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)

if [ -z "$INTERFACE" ]; then
    echo "[!] Error crítico: No se detectó una interfaz con salida a internet."
    exit 1
fi

echo "[+] Interfaz física activa: $INTERFACE"

if systemctl is-active --quiet NetworkManager; then
    echo "[+] Configurando IPs en NetworkManager..."
    NM_CONN=$(nmcli -t -f DEVICE,NAME connection show --active | grep "^${INTERFACE}:" | cut -d: -f2)
    if [ -n "$NM_CONN" ]; then
        # Asignamos AMBAS IPs a la misma interfaz física
        nmcli connection modify "$NM_CONN" ipv4.addresses "$LANCACHE_IP/$NETMASK_SHORT,$PIHOLE_IP/$NETMASK_SHORT"
        nmcli connection modify "$NM_CONN" ipv4.gateway "$GATEWAY"
        nmcli connection modify "$NM_CONN" ipv4.dns "$DNS_PROVISIONAL"
        nmcli connection modify "$NM_CONN" ipv4.method manual
        nmcli connection up "$NM_CONN"
    else
        echo "[!] Falló el mapeo en NetworkManager. Se intentará forzar por comando 'ip'."
        ip addr add "$LANCACHE_IP/$NETMASK_SHORT" dev "$INTERFACE" || true
        ip addr add "$PIHOLE_IP/$NETMASK_SHORT" dev "$INTERFACE" || true
    fi

elif systemctl is-active --quiet systemd-networkd; then
    echo "[+] Configurando IPs en systemd-networkd..."
    NET_FILE="/etc/systemd/network/10-static-en.network"
    cat <<EOF > "$NET_FILE"
[Match]
Name=$INTERFACE

[Network]
Address=$LANCACHE_IP/$NETMASK_SHORT
Address=$PIHOLE_IP/$NETMASK_SHORT
Gateway=$GATEWAY
DNS=$DNS_PROVISIONAL
EOF
    systemctl restart systemd-networkd

elif systemctl is-active --quiet dhcpcd; then
    echo "[+] Configurando IPs en dhcpcd..."
    sed -i "/interface $INTERFACE/,+5d" /etc/dhcpcd.conf
    cat <<EOF >> /etc/dhcpcd.conf

interface $INTERFACE
static ip_address=$LANCACHE_IP/$NETMASK_SHORT
static ip_address=$PIHOLE_IP/$NETMASK_SHORT
static routers=$GATEWAY
static domain_name_servers=$DNS_PROVISIONAL
EOF
    systemctl restart dhcpcd
else
    echo "[!] No se reconoció un gestor activo. Aplicando IPs de forma volátil mediante comando ip..."
    ip addr add "$LANCACHE_IP/$NETMASK_SHORT" dev "$INTERFACE" || true
    ip addr add "$PIHOLE_IP/$NETMASK_SHORT" dev "$INTERFACE" || true
fi

# ==========================================
# 4. PREPARACIÓN DEL DISCO DE ALMACENAMIENTO
# ==========================================
echo ""
echo "[?] Discos de almacenamiento disponibles:"
echo "---------------------------------------------------------"
lsblk -n -o NAME,SIZE,FSTYPE,MODEL
echo "---------------------------------------------------------"
read -p "[>] Escribe el nombre exacto de la partición para los juegos (ej. sda1): " DISK_NAME

if [ ! -b "/dev/$DISK_NAME" ]; then
    echo "[!] El dispositivo /dev/$DISK_NAME no existe."
    exit 1
fi

MOUNT_POINT="/mnt/lancache"
sudo mkdir -p "$MOUNT_POINT"

# Forzar la lectura de UUID y TYPE con sudo o lsblk como respaldo
DISK_UUID=$(sudo blkid -o value -s UUID "/dev/$DISK_NAME")
FS_TYPE=$(sudo blkid -o value -s TYPE "/dev/$DISK_NAME")

if [ -z "$DISK_UUID" ] || [ -z "$FS_TYPE" ]; then
    DISK_UUID=$(lsblk -no UUID "/dev/$DISK_NAME")
    FS_TYPE=$(lsblk -no FSTYPE "/dev/$DISK_NAME")
fi

if [ -z "$DISK_UUID" ] || [ -z "$FS_TYPE" ]; then
    echo "[!] No se pudo leer un sistema de archivos válido en la partición /dev/$DISK_NAME."
    exit 1
fi

# DETECTAR SI YA ESTÁ MONTADO EN OTRO LUGAR
CURRENT_MOUNT=$(lsblk -no MOUNTPOINT "/dev/$DISK_NAME" | head -n 1)

if [ -n "$CURRENT_MOUNT" ] && [ "$CURRENT_MOUNT" != "$MOUNT_POINT" ]; then
    echo "[-] El disco ya está montado en: $CURRENT_MOUNT"
    echo "[-] Desmontando de forma segura para reasignarlo a $MOUNT_POINT..."
    sudo umount -l "$CURRENT_MOUNT" || true
fi

# LIMPIAR CONFIGURACIONES PREVIAS EN FSTAB
sudo sed -i "\|UUID=$DISK_UUID|d" /etc/fstab
sudo sed -i "\|$MOUNT_POINT|d" /etc/fstab

# Escribir la nueva configuración limpia óptima para Linux (ext4/xfs)
echo "UUID=$DISK_UUID $MOUNT_POINT $FS_TYPE defaults,noatime,nofail 0 2" | sudo tee -a /etc/fstab

echo "[-] Montando la unidad de almacenamiento en su ubicación final..."
sudo mount -a || true

# Verificación definitiva de montaje activo
if ! mountpoint -q "$MOUNT_POINT"; then
    sudo mount "/dev/$DISK_NAME" "$MOUNT_POINT" || true
    if ! mountpoint -q "$MOUNT_POINT"; then
        echo "[!] Error crítico: La unidad no se pudo montar en $MOUNT_POINT."
        exit 1
    fi
fi

# AJUSTAR PROPIEDAD DE LA RAÍZ DEL DISCO MONTAJE (Vital para formatos Linux)
# Detecta el usuario real que invocó sudo en lugar de asignar root de forma ciega
REAL_USER=$(logname 2>/dev/null || echo $USER)
sudo chown -R "$REAL_USER":"$REAL_USER" "$MOUNT_POINT"

CACHE_DATA_DIR="$MOUNT_POINT/data"
CACHE_LOGS_DIR="$MOUNT_POINT/logs"
PIHOLE_DATA_DIR="/opt/pihole/config"
PIHOLE_DNS_DIR="/opt/pihole/dnsmasq.d"

# Crear directorios con la estructura correcta
mkdir -p "$CACHE_DATA_DIR" "$CACHE_LOGS_DIR"
sudo mkdir -p "$PIHOLE_DATA_DIR" "$PIHOLE_DNS_DIR"

# Asignar permisos globales para los contenedores de Lancache
chmod -R 777 "$CACHE_DATA_DIR" "$CACHE_LOGS_DIR"
sudo chmod -R 777 "/opt/pihole"

echo "[+] Almacenamiento Linux preparado, montado y con permisos verificados en $MOUNT_POINT."

# ==========================================
# 5. CREACIÓN DEL ESCENARIO DOCKER COMPOSE
# ==========================================
echo ""
echo "[-] Generando la infraestructura integrada en /opt/servicios..."
mkdir -p /opt/servicios
cd /opt/servicios

# Escribimos el docker-compose asignando de forma estricta los sockets a cada IP específica
cat << EOF > docker-compose.yml
version: '3.8'

services:
  # --- BLOQUE PI-HOLE (Escucha en la IP Virtual .8) ---
  pihole:
    container_name: pihole
    image: pihole/pihole:latest
    restart: always
    ports:
      - "${PIHOLE_IP}:53:53/udp"
      - "${PIHOLE_IP}:53:53/tcp"
      - "${PIHOLE_IP}:80:80/tcp"
    environment:
      TZ: 'Europe/Madrid'
      WEBPASSWORD: '${PASSWORD_PIHOLE}'
      PIHOLE_DNS_: '1.1.1.1;8.8.8.8'
      INTERFACE: 'eth0'
    volumes:
      - '${PIHOLE_DATA_DIR}:/etc/pihole'
      - '${PIHOLE_DNS_DIR}:/etc/dnsmasq.d'

  # --- BLOQUE LANCACHE DNS (Escucha en la IP Principal .7 y sale por Pi-hole) ---
  lancache-dns:
    container_name: lancache-dns
    image: lancachenet/lancache-dns:latest
    restart: always
    ports:
      - "${LANCACHE_IP}:53:53/udp"
      - "${LANCACHE_IP}:53:53/tcp"
    environment:
      - LANCACHE_IP=${LANCACHE_IP}
      - UPSTREAM_DNS=${PIHOLE_IP} # Redirige el tráfico limpio a Pi-hole

  # --- BLOQUE LANCACHE MONOLITHIC (Escucha puertos Web en la IP Principal .7) ---
  lancache-monolithic:
    container_name: lancache-monolithic
    image: lancachenet/monolithic:latest
    restart: always
    ports:
      - "${LANCACHE_IP}:80:80/tcp"
      - "${LANCACHE_IP}:443:443/tcp"
    environment:
      - CACHE_DISK_SIZE=1000g
      - TZ=Europe/Madrid
    volumes:
      - ${CACHE_DATA_DIR}:/data/cache
      - ${CACHE_LOGS_DIR}:/data/logs
EOF

# ==========================================
# 6. DESPLIEGUE Y CONFIGURACIÓN FINAL DEL HOST
# ==========================================
echo ""
echo "[-] Levantando contenedores en Docker..."
echo "---------------------------------------------------------"
docker compose up -d

echo ""
echo "[-] Aplicando configuración DNS final en el Host local..."
if [ -n "$INTERFACE" ]; then
    if systemctl is-active --quiet NetworkManager; then
        NM_CONN=$(nmcli -t -f DEVICE,NAME connection show --active | grep "^${INTERFACE}:" | cut -d: -f2 | head -n 1)
        if [ -n "$NM_CONN" ]; then
            nmcli connection modify "$NM_CONN" ipv4.dns "$LANCACHE_IP"
            nmcli connection up "$NM_CONN"
        fi
