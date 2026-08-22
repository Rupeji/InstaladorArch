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

# ==========================================
# 0.1 INSTALACIÓN DE DEPENDENCIAS NECESARIAS
# ==========================================
echo ""
echo "[-] Actualizando repositorios e instalando paquetes necesarios..."
echo "---------------------------------------------------------"

# Se añade openssh a la lista de paquetes esenciales de Arch Linux
pacman -Sy --noconfirm
pacman -S --needed --noconfirm git curl lsblk docker docker-compose neofetch nano openssh

echo "[-] Configurando e iniciando los servicios del sistema..."
# Inicia y habilita Docker
systemctl enable --now docker

# Inicia y habilita el servidor SSH (sshd) de forma automática
echo "[-] Habilitando el servidor OpenSSH para conexiones remotas..."
systemctl enable --now sshd
echo "---------------------------------------------------------"

# Variables de Red fijas
LANCACHE_IP="192.168.0.7"
NETMASK_SHORT="24" # Equivale a 255.255.255.0

# NOTA: Esta es la IP de la puerta de enlace (tu router local)
GATEWAY="192.168.0.1" 

DNS_PROVISIONAL="1.1.1.1" # DNS temporal para descargar las imágenes de Docker

# ==========================================
# 1. SELECCIÓN DE DISCO DURO PARA LOS JUEGOS
# ==========================================
echo ""
echo "[?] Discos de almacenamiento disponibles en el sistema:"
echo "---------------------------------------------------------"
lsblk -d -n -o NAME,SIZE,MODEL
echo "---------------------------------------------------------"

read -p "[>] Escribe el nombre exacto del disco para LanCache (ej. sdb o nvme1n1): " DISK_NAME

# Validar que el dispositivo de bloque realmente existe en el sistema
if [ ! -b "/dev/$DISK_NAME" ]; then
    echo "[!] Error crítico: El disco /dev/$DISK_NAME no es un dispositivo válido o no existe."
    exit 1
fi

echo ""
echo "[!] ADVERTENCIA CRÍTICA: Se van a borrar y formatear todos los datos en /dev/$DISK_NAME"
read -p "[?] ¿Estás completamente seguro de continuar con el formateo? (s/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
    echo "[-] Operación cancelada de forma segura por el usuario."
    exit 0
fi

# Formatear el disco utilizando el sistema de archivos estándar EXT4
echo "[-] Formateando /dev/$DISK_NAME en formato EXT4..."
mkfs.ext4 -F "/dev/$DISK_NAME"

# Configurar el punto de montaje del sistema
MOUNT_POINT="/mnt/lancache"
mkdir -p "$MOUNT_POINT"

# Extraer el UUID único del disco para evitar problemas si cambia el orden de los cables
DISK_UUID=$(blkid -o value -s UUID "/dev/$DISK_NAME")

echo "[-] Añadiendo entrada persistente en /etc/fstab mediante UUID..."
if ! grep -q "$DISK_UUID" /etc/fstab; then
    echo "UUID=$DISK_UUID $MOUNT_POINT ext4 defaults,noatime 0 2" >> /etc/fstab
fi

echo "[-] Montando la nueva unidad..."
mount -a

# Estructurar las carpetas internas requeridas por LanCache dentro del disco seleccionado
CACHE_DATA_DIR="$MOUNT_POINT/data"
CACHE_LOGS_DIR="$MOUNT_POINT/logs"
mkdir -p "$CACHE_DATA_DIR" "$CACHE_LOGS_DIR"

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
echo "    Servicio SSH: Activo (Puerto por defecto: 22)"
echo "    Aviso: Recuerda redirigir el DNS de tus consolas/PC a la IP $LANCACHE_IP"
echo "========================================================="
neofetch
