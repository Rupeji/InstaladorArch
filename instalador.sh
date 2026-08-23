#!/bin/bash

# Evitar que el script continúe si hay un error
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
NETMASK_SHORT="24" # Equivale a 255.255.255.0
GATEWAY="192.168.0.1" 
DNS_PROVISIONAL="1.1.1.1" # DNS temporal para descargar las imágenes de Docker

# ==========================================
# 0.1 INSTALACIÓN DE DEPENDENCIAS NECESARIAS
# ==========================================
echo ""
echo "[-] Actualizando repositorios e instalando paquetes necesarios..."
echo "---------------------------------------------------------"

# Se instala openssh junto con el resto de herramientas esenciales
pacman -Sy --noconfirm
pacman -S --needed --noconfirm git curl util-linux docker docker-compose fastfetch nano openssh

echo "[-] Configurando e iniciando los servicios del sistema..."
# Inicia y habilita Docker
systemctl enable --now docker

# Inicia y habilita el servidor SSH (sshd)
echo "[-] Habilitando el servidor OpenSSH para conexiones remotas..."
systemctl enable --now sshd

# Configuración automática para permitir el acceso SSH al usuario root con contraseña
echo "[-] Configurando permisos de OpenSSH para permitir el acceso SSH a Root..."
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
# Por si la directiva estaba comentada de otra forma o no existía, aseguramos su presencia
if ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
fi

# Reiniciar el servicio SSH para aplicar la nueva directiva de acceso root
systemctl restart sshd

# ==========================================
# 0.2 CONFIGURACIÓN INTELIGENTE DE IP ESTÁTICA
# ==========================================
echo "---------------------------------------------------------"
echo "[-] Detectando gestor de red activo para aplicar IP estática..."

# Obtener el nombre de la interfaz de red principal conectada a internet
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)

if [ -z "$INTERFACE" ]; then
    echo "[!] Advertencia: No se detectó ninguna interfaz de red activa con salida a internet."
    echo "    Se omitirá la configuración automática de IP estática."
else
    echo "[+] Interfaz de red detectada: $INTERFACE"
    
    # 1. Detección y configuración para NetworkManager
    if systemctl is-active --quiet NetworkManager; then
        echo "[+] Detectado NetworkManager activo. Configurando IP estática..."
        nmcli connection modify "$INTERFACE" ipv4.addresses "$LANCACHE_IP/$NETMASK_SHORT"
        nmcli connection modify "$INTERFACE" ipv4.gateway "$GATEWAY"
        nmcli connection modify "$INTERFACE" ipv4.dns "$DNS_PROVISIONAL"
        nmcli connection modify "$INTERFACE" ipv4.method manual
        nmcli connection up "$INTERFACE"
        echo "[+] NetworkManager configurado correctamente."

    # 2. Detección y configuración para systemd-networkd
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

    # 3. Detección y configuración para dhcpcd
    elif systemctl is-active --quiet dhcpcd; then
        echo "[+] Detectado dhcpcd activo. Configurando IP estática..."
        # Evitar duplicar la configuración si se ejecuta el script varias veces
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
        echo "    Por favor, asegúrate de fijar la IP $LANCACHE_IP manualmente."
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

# Validar que el dispositivo de bloque realmente existe en el sistema
if [ ! -b "/dev/$DISK_NAME" ]; then
    echo "[!] Error crítico: El disco /dev/$DISK_NAME no es un dispositivo válido o no existe."
    exit 1
fi

# Configurar el punto de montaje del sistema
MOUNT_POINT="/mnt/lancache"
mkdir -p "$MOUNT_POINT"

# Extraer el UUID único del disco para el montaje persistente
DISK_UUID=$(blkid -o value -s UUID "/dev/$DISK_NAME")
FS_TYPE=$(blkid -o value -s TYPE "/dev/$DISK_NAME")

# Verificar si el UUID y el formato son correctos
if [ -z "$DISK_UUID" ] || [ -z "$FS_TYPE" ]; then
    echo "[!] Error: No se pudo leer el sistema de archivos de /dev/$DISK_NAME."
    echo "    Asegúrate de escribir el nombre de la partición ya formateada (ej. sdb1, no sdb)."
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
    mount -a
fi

# Estructurar las carpetas internas requeridas por LanCache dentro del disco seleccionado
CACHE_DATA_DIR="$MOUNT_POINT/data"
CACHE_LOGS_DIR="$MOUNT_POINT/logs"
echo "[-] Creando la estructura inicial de directorios en la unidad vacía..."
mkdir -p "$CACHE_DATA_DIR" "$CACHE_LOGS_DIR"

# Otorgar permisos globales a las carpetas del disco para evitar bloqueos de Docker
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
cat <<EOF > docker-compose.yml
version: '2'

services:
  dns:
    image: lancachenet/lancache-dns:latest
    restart: always
    ports:
      - ${LANCACHE_IP}:53:53/udp
      - ${LANCACHE_IP}:53:53/tcp
    environment:
      - LANCACHE_IP=${LANCACHE_IP}
      - UPSTREAM_DNS=${DNS_PROVISIONAL}

  cache:
    image: lancachenet/monolithic:latest
    restart: always
    ports:
      - ${LANCACHE_IP}:80:80/tcp
      - ${LANCACHE_IP}:443:443/tcp
    environment:
      - CACHE_DISK_SIZE=1000g
      - TZ=Europe/Madrid
    volumes:
      - ${CACHE_DATA_DIR}:/data/cache
      - ${CACHE_LOGS_DIR}:/data/logs
EOF

# ==========================================
# 3. DESPLIEGUE AUTOMÁTICO DE LOS CONTENEDORES
# ==========================================
echo ""
echo "[-] Descargando imágenes e iniciando LanCache mediante Docker Compose..."
echo "---------------------------------------------------------"
docker-compose up -d

echo ""
echo "========================================================="
echo "[+] ¡El proceso de instalación ha finalizado de forma correcta!"
echo "    Dirección IP fija asignada a LanCache: $LANCACHE_IP"
echo "    Punto de montaje del almacenamiento: $MOUNT_POINT"
echo "    Servicio SSH: Activo y configurado para acceso Root (Puerto: 22)"
echo "    Aviso: Recuerda redirigir el DNS de tus consolas/PC a la IP $LANCACHE_IP"
echo "========================================================="
fastfetch
