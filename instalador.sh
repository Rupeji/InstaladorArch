bash#!/bin/bash

# Evitar que el script continúe si hay un error
set -e

echo "========================================================="
echo " Instalador Automatizado: Red Estática + Selección de Disco + LanCache "
echo "========================================================="

# ==========================================
# 0. COMPROBACIÓN DE PRIVILEGIOS
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo "[-] Este script necesita permisos de administrador (root)."
    if command -v sudo >/dev/null 2>&1; then
        echo "[-] Solicitando privilegios mediante sudo..."
        # Ejecuta el script de nuevo usando sudo, manteniendo los argumentos si los hubiera
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

# Actualizar e instalar dependencias principales de forma desatendida (excluyendo wget)
pacman -Sy --noconfirm
pacman -S --needed --noconfirm wget nano neofetch curl lsblk docker docker-compose

echo "[-] Configurando e iniciando el servicio de Docker..."
systemctl enable --now docker
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
echo "[-] Buscando discos duros disponibles..."
echo "---------------------------------------------------------"
# Listar los discos físicos disponibles excluyendo bucles (loop) y particiones ram (zram)
mapfile -t DISK_LIST < <(lsblk -dno NAME,SIZE,MODEL | grep -v -E "loop|zram")

if [ ${#DISK_LIST[@]} -eq 0 ]; then
    echo "[!] No se detectaron discos adicionales. Se usará el directorio actual."
    BASE_DIR=$(pwd)
else
    echo "Selecciona el número del disco donde quieres almacenar los juegos:"
    for i in "${!DISK_LIST[@]}"; do
        echo "  [$i] /dev/$(echo "${DISK_LIST[$i]}" | awk '{print $1}') - $(echo "${DISK_LIST[$i]}" | cut -d' ' -f2-)"
    done
    echo "  [s] Usar el directorio actual del script ($(pwd))"
    echo "---------------------------------------------------------"
    
    read -p "Introduce tu opción: " disk_choice

    if [[ "$disk_choice" =~ ^[0-9]+$ ]] && [ "$disk_choice" -lt "${#DISK_LIST[@]}" ]; then
        SELECTED_DISK=$(echo "${DISK_LIST[$disk_choice]}" | awk '{print $1}')
        
        # Detectar el punto de montaje del disco seleccionado
        MOUNT_POINT=$(lsblk -no MOUNTPOINTS "/dev/$SELECTED_DISK" | grep -v '^$' | head -n1)
        
        if [ -z "$MOUNT_POINT" ]; then
            echo "[!] El disco /dev/$SELECTED_DISK no parece estar montado."
            echo "[!] Por seguridad, móntalo antes de ejecutar el script o elige 's' para continuar en la ruta actual."
            exit 1
        fi
        
        BASE_DIR="${MOUNT_POINT}/lancache_data"
        echo "[-] Almacenamiento configurado en el disco: /dev/$SELECTED_DISK (Ruta: $BASE_DIR)"
    else
        BASE_DIR=$(pwd)
        echo "[-] Almacenamiento configurado en el directorio actual: $BASE_DIR"
    fi
fi

# Crear directorios en la ruta seleccionada
echo "[-] Creando directorios para almacenar datos persistentes..."
mkdir -p "$BASE_DIR/lancache/data" "$BASE_DIR/lancache/logs" "$BASE_DIR/lancache/cache"
mkdir -p "$BASE_DIR/pihole/config" "$BASE_DIR/pihole/dnsmasq"
mkdir -p "$BASE_DIR/nine-ui"

# Ir al directorio base para centralizar los archivos .env y docker-compose.yml
cd "$BASE_DIR"

# ==========================================
# 2. CONFIGURACIÓN DE LA INTERFAZ DE RED
# ==========================================
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)
fi
echo "[-] Interfaz de red detectada: ${INTERFACE}"

if systemctl is-active --quiet NetworkManager; then
    echo "[-] Detectado: NetworkManager activo. Configurando IP estática..."
    NM_CONN=$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE" | head -n1)
    if [ -z "$NM_CONN" ]; then NM_CONN="$INTERFACE"; fi
    
    nmcli connection modify "$NM_CONN" ipv4.addresses "${LANCACHE_IP}/${NETMASK_SHORT}"
    nmcli connection modify "$NM_CONN" ipv4.gateway "${GATEWAY}"
    nmcli connection modify "$NM_CONN" ipv4.dns "${DNS_PROVISIONAL}"
    nmcli connection modify "$NM_CONN" ipv4.method manual
    nmcli connection up "$NM_CONN"

elif systemctl is-active --quiet systemd-networkd; then
    echo "[-] Detectado: systemd-networkd activo. Configurando IP estática..."
    mkdir -p /etc/systemd/network
    cat << EOF | tee /etc/systemd/network/10-${INTERFACE}.network > /dev/null
[Match]
Name=${INTERFACE}

[Network]
Address=${LANCACHE_IP}/${NETMASK_SHORT}
Gateway=${GATEWAY}
DNS=${DNS_PROVISIONAL}
EOF
    systemctl restart systemd-networkd
else
    echo "[!] ADVERTENCIA: No se detectó NetworkManager ni systemd-networkd activo."
    ip addr add ${LANCACHE_IP}/${NETMASK_SHORT} dev ${INTERFACE} 2>/dev/null || true
    ip route add default via ${GATEWAY} dev ${INTERFACE} 2>/dev/null || true
fi

# ==========================================
# 3. SOLUCIONAR CONFLICTO PUERTO 53
# ==========================================
if systemctl is-active --quiet systemd-resolved; then
    echo "[-] Desactivando el stub de DNS de systemd-resolved..."
    mkdir -p /etc/systemd/resolved.conf.d/
    echo -e "[Resolve]\nDNSStubListener=no" | tee /etc/systemd/resolved.conf.d/lancache.conf > /dev/null
    systemctl restart systemd-resolved
fi

# ==========================================
# 4. GENERAR ARCHIVOS DE CONFIGURACIÓN
# ==========================================
TZ=$(cat /etc/timezone 2>/dev/null || echo "Europe/Madrid")

echo "[-] Generando archivo de configuración .env..."
cat << EOF > .env
LANCACHE_IP=${LANCACHE_IP}
TZ=${TZ}
CACHE_DISK_SIZE=1000g
CACHE_MAX_AGE=3650d
UPSTREAM_DNS=1.1.1.1
WEBPASSWORD=Pacopicopoco.7
EOF

echo "[-] Generando archivo docker-compose.yml..."
cat << 'EOF' > docker-compose.yml
version: '3.8'

services:
  lancache:
    image: lancachenet/monolithic:latest
    container_name: lancache
    restart: unless-stopped
    env_file: .env
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./lancache/cache:/data/cache
      - ./lancache/logs:/data/logs

  lancache-dns:
    image: lancachenet/lancache-dns:latest
    container_name: lancache-dns
    restart: unless-stopped
    env_file: .env
    ports:
      - "${LANCACHE_IP}:53:53/udp"
      - "${LANCACHE_IP}:53:53/tcp"

  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    restart: unless-stopped
    env_file: .env
    ports:
      - "127.0.0.1:53:53/udp"
      - "127.0.0.1:53:53/tcp"
      - "8080:80/tcp"
    environment:
      - PIHOLE_DNS_=${LANCACHE_IP}
    volumes:
      - ./pihole/config:/etc/pihole
      - ./pihole/dnsmasq:/etc/dnsmasq.d/
    depends_on:
      - lancache-dns

  nine-lancache-ui:
    image: spritsail/nine-lancache-ui:latest
    container_name: nine-lancache-ui
    restart: unless-stopped
    ports:
      - "8000:80"
    environment:
      - TZ=${TZ}
    volumes:
      - ./lancache/logs:/logs:ro
    depends_on:
      - lancache
EOF

chown -R 1000:1000 lancache/logs 2>/dev/null || true

# ==========================================
# 5. INICIAR CONTENEDORES Y AJUSTAR DNS FINAL
# ==========================================
echo "[-] Descargando e iniciando servicios en Docker..."
docker-compose up -d

echo "[-] Redirigiendo el DNS de este servidor al Pi-hole local..."
if systemctl is-active --quiet NetworkManager; then
    nmcli connection modify "$NM_CONN" ipv4.dns "127.0.0.1"
    nmcli connection up "$NM_CONN" > /dev/null
elif systemctl is-active --quiet systemd-networkd; then
    sed -i 's/DNS=.*/DNS=127.0.0.1/' /etc/systemd/network/10-${INTERFACE}.network
    systemctl restart systemd-networkd
fi

echo "========================================================="
echo " ¡Instalación Completada con Éxito!"
echo "========================================================="
echo " Todo se ha instalado en: $BASE_DIR"
echo " Tu IP fija configurada es: ${LANCACHE_IP}"
echo ""
echo " Accesos web disponibles:"
echo " -> Pi-hole:            http://${LANCACHE_IP}:8080/admin"
echo "    (Nueva contraseña: Pacopicopoco.7)"
echo " -> Nine-LanCache-UI:   http://${LANCACHE_IP}:8000"
echo "========================================================="
