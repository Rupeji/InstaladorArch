#!/bin/bash

# Evitar que el script continúe si hay un error crítico
set -e

echo "========================================================="
echo " Instalador Automatizado: Red Estática + Selección de Disco + LanCache + SSH "
echo "========================================================="

# ==========================================
# 0. COMPROBACIÓN DE PRIVILEGIOS
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo "[-] Este script necesita permisos de administrador (root)."
    if command -v sudo >/dev/null 2>&1; then
        echo "[-] Solicitando privilegios mediante sudo..."
        exec sudo "$0" "$@"
    else
        echo "[!] Error: Este script requiere permisos de root y 'sudo' no está instalado."
        echo "    Por favor, ejecuta el script directamente como root o instala sudo."
        exit 1
    fi
fi

echo "[-] Privilegios de administrador verificados correctamente."

# Variables de Red fijas
LANCACHE_IP="192.168.0.7"
NETMASK_SHORT="24" 
GATEWAY="192.168.0.1" 
DNS_PROVISIONAL="1.1.1.1" # Mantenido obligatoriamente en el OS hasta que Docker esté activo

# ==========================================
# 0.1 INSTALACIÓN DE DEPENDENCIAS NECESARIAS
# ==========================================
echo ""
echo "[-] Actualizando repositorios e instalando paquetes necesarios..."
echo "---------------------------------------------------------"

pacman -Sy --noconfirm
# Corregido: Se instala docker-compose-v2 para el soporte nativo moderno de Arch Linux
pacman -S --needed --noconfirm git curl util-linux docker docker-compose-v2 fastfetch nano openssh

echo "[-] Configurando e iniciando los servicios del sistema..."
systemctl enable --now docker
systemctl enable --now sshd

echo "[-] Configurando permisos de OpenSSH para permitir el acceso SSH a Root..."
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
if ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
fi
systemctl restart sshd

# ==========================================
# 0.2 CONFIGURACIÓN INTELIGENTE DE IP ESTÁTICA
# ==========================================
echo "---------------------------------------------------------"
echo "[-] Detectando gestor de red activo para aplicar IP estática..."

INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)

if [ -z "$INTERFACE" ]; then
    echo "[!] Advertencia: No se detectó ninguna interfaz de red activa con salida a internet."
    echo "    Se omitirá la configuración automática de IP estática."
else
    echo "[+] Interfaz de red detectada: $INTERFACE"
    
    # 1. Configuración para NetworkManager
    if systemctl is-active --quiet NetworkManager; then
        echo "[+] Detectado NetworkManager activo. Configurando IP estática..."
        NM_CONN=$(nmcli -t -f DEVICE,NAME connection show --active | grep "^${INTERFACE}:" | cut -d: -f2)
        if [ -n "$NM_CONN" ]; then
            nmcli connection modify "$NM_CONN" ipv4.addresses "$LANCACHE_IP/$NETMASK_SHORT"
            nmcli connection modify "$NM_CONN" ipv4.gateway "$GATEWAY"
            nmcli connection modify "$NM_CONN" ipv4.dns "$DNS_PROVISIONAL" # Mantiene internet para Docker
            nmcli connection modify "$NM_CONN" ipv4.method manual
            nmcli connection up "$NM_CONN"
            echo "[+] NetworkManager configurado correctamente."
        else
            echo "[!] No se pudo mapear la interfaz a una conexión de NetworkManager."
        fi

    # 2. Configuración para systemd-networkd
    elif systemctl is-active --quiet systemd-networkd; then
        echo "[+] Detectado systemd-networkd activo. Configurando IP estática..."
        NET_FILE="/etc/systemd/network/10-static-en.network"
        cat <<EOF > "$NET_FILE"
[Match]
Name=$INTERFACE

[Network]
Address=$LANCACHE_IP/$NETMASK_SHORT
Gateway=$GATEWAY
DNS=$DNS_PROVISIONAL
EOF
        systemctl restart systemd-networkd
        echo "[+] systemd-networkd configurado correctamente."

    # 3. Configuración para dhcpcd
    elif systemctl is-active --quiet dhcpcd; then
        echo "[+] Detectado dhcpcd activo. Configurando IP estática..."
        sed -i "/interface $INTERFACE/,+4d" /etc/dhcpcd.conf
        cat <<EOF >> /etc/dhcpcd.conf

interface $INTERFACE
static ip_address=$LANCACHE_IP/$NETMASK_SHORT
static routers=$GATEWAY
static domain_name_servers=$DNS_PROVISIONAL
EOF
        systemctl restart dhcpcd
        echo "[+] dhcpcd configurado correctamente."
    
    else
        echo "[!] No se detectó NetworkManager, systemd-networkd ni dhcpcd activo."
    fi
fi
echo "---------------------------------------------------------"

# ==========================================
# 1. SELECCIÓN DE DISCO DURO PARA LOS JUEGOS
# ==========================================
echo ""
echo "[?] Discos de almacenamiento disponibles en el sistema:"
echo "---------------------------------------------------------"
lsblk -n -o NAME,SIZE,FSTYPE,MODEL
echo "---------------------------------------------------------"

read -p "[>] Escribe el nombre exacto de la partición vacía formateada (ej. sdb1 o nvme1n1p1): " DISK_NAME

if [ ! -b "/dev/$DISK_NAME" ]; then
    echo "[!] Error crítico: El disco /dev/$DISK_NAME no es un dispositivo válido o no existe."
    exit 1
fi

MOUNT_POINT="/mnt/lancache"
mkdir -p "$MOUNT_POINT"

DISK_UUID=$(blkid -o value -s UUID "/dev/$DISK_NAME")
FS_TYPE=$(blkid -o value -s TYPE "/dev/$DISK_NAME")

if [ -z "$DISK_UUID" ] || [ -z "$FS_TYPE" ]; then
    echo "[!] Error: No se pudo leer el sistema de archivos de /dev/$DISK_NAME."
    exit 1
fi

echo "[-] Añadiendo entrada persistente en /etc/fstab mediante UUID..."
if ! grep -q "$DISK_UUID" /etc/fstab; then
    echo "UUID=$DISK_UUID $MOUNT_POINT $FS_TYPE defaults,noatime 0 2" >> /etc/fstab
fi

echo "[-] Asegurando el montaje de la unidad..."
if mount | grep -q "$MOUNT_POINT"; then
    echo "[-] La unidad ya se encontraba montada en $MOUNT_POINT."
else
    # Corregido: Evita que advertencias menores del sistema colapsen el script bajo 'set -e'
    mount -a || true
    if ! mount | grep -q "$MOUNT_POINT"; then
        echo "[!] Error crítico: No se pudo montar la unidad en $MOUNT_POINT."
        exit 1
    fi
fi

CACHE_DATA_DIR="$MOUNT_POINT/data"
CACHE_LOGS_DIR="$MOUNT_POINT/logs"
mkdir -p "$CACHE_DATA_DIR" "$CACHE_LOGS_DIR"
chmod -R 777 "$CACHE_DATA_DIR" "$CACHE_LOGS_DIR"

# ==========================================
# 2. CONFIGURACIÓN DEL ENTORNO LANCACHE
# ==========================================
echo ""
echo "[-] Creando el directorio operativo de LanCache..."
LANCACHE_DIR="/opt/lancache"
mkdir -p "$LANCACHE_DIR"
cd "$LANCACHE_DIR"

echo "[-] Generando archivo docker-compose.yml con las variables de red..."
cat << 'EOF' > docker-compose.yml
version: '2'

services:
  dns:
    image: lancachenet/lancache-dns:latest
    restart: always
    ports:
      - "192.168.0.7:53:53/udp"
      - "192.168.0.7:53:53/tcp"
    environment:
      - LANCACHE_IP=192.168.0.7
      - UPSTREAM_DNS=1.1.1.1

  cache:
    image: lancachenet/monolithic:latest
    restart: always
    ports:
      - "192.168.0.7:80:80/tcp"
      - "192.168.0.7:443:443/tcp"
    environment:
      - CACHE_DISK_SIZE=1000g
      - TZ=Europe/Madrid
    volumes:
      - /mnt/lancache/data:/data/cache
      - /mnt/lancache/logs:/data/logs
EOF

echo "[+] Archivo docker-compose.yml creado con éxito."

# ==========================================
# 3. DESPLIEGUE AUTOMÁTICO DE LOS CONTENEDORES
# ==========================================
echo ""
echo "[-] Descargando imágenes e iniciando LanCache mediante Docker Compose..."
echo "---------------------------------------------------------"

# Ahora Docker resolverá perfectamente las descargas porque la máquina conserva DNS real temporal externo
docker compose up -d

# ==========================================
# 4. CAMBIO DE DNS FINAL (POST-INSTALACIÓN)
# ==========================================
echo ""
echo "[-] Aplicando redirección definitiva de DNS interno en la máquina host..."
if [ -n "$INTERFACE" ]; then
    if systemctl is-active --quiet NetworkManager; then
        nmcli connection modify "$NM_CONN" ipv4.dns "$LANCACHE_IP"
        nmcli connection up "$NM_CONN"
    elif systemctl is-active --quiet systemd-networkd; then
        sed -i "s/DNS=$DNS_PROVISIONAL/DNS=$LANCACHE_IP/" "$NET_FILE"
        systemctl restart systemd-networkd
    elif systemctl is-active --quiet dhcpcd; then
        sed -i "s/static domain_name_servers=$DNS_PROVISIONAL/static domain_name_servers=$LANCACHE_IP/" /etc/dhcpcd.conf
        systemctl restart dhcpcd
    fi
fi

echo ""
echo "========================================================="
echo "[+] ¡El proceso de instalación ha finalizado de forma correcta!"
echo "    Dirección IP fija asignada a LanCache: $LANCACHE_IP"
echo "    Punto de montaje del almacenamiento: $MOUNT_POINT"
echo "    Servicio SSH: Activo y configurado para acceso Root (Puerto: 22)"
echo "    Aviso: Recuerda redirigir el DNS de tus consolas/PC a la IP $LANCACHE_IP"
echo "========================================================="
fastfetch
