#!/usr/bin/env bash

# Salir inmediatamente si un comando falla de forma imprevista
set -e

# Configuración de variables fijas solicitadas
LANCACHE_IP="192.168.0.7"

echo "======================================================="
echo "=== PASO 1: INSTALACIÓN DE DEPENDENCIAS DEL SISTEMA ==="
echo "======================================================="

# Guardar la versión del kernel antes de actualizar para prevenir colapso de módulos de Docker
KERNEL_ANTES=$(uname -r)

echo "--> Actualizando el sistema completo de Arch Linux (Pacman -Syu)..."
sudo pacman -Syu --noconfirm

echo "--> Instalando dependencias estructurales y binarios de red..."
# Docker y su plugin CLI de compose se gestionan juntos de forma nativa en Arch
sudo pacman -S --needed --noconfirm \
    docker \
    docker-compose \
    containerd \
    git \
    coreutils \
    glibc \
    iptables-nft \
    util-linux \
    gawk \
    iproute2 \
    dnssec-anchors \
    openresolv

# Verificar si pacman modificó el kernel en caliente y borró los módulos en ejecución
KERNEL_AHORA=$(pacman -Q linux | awk '{print $2}' || echo "unknown")
if [[ "$KERNEL_ANTES" != *"$KERNEL_AHORA"* ]] && [ -d "/usr/lib/modules/$KERNEL_ANTES" ] && [ ! -d "/usr/lib/modules/$(uname -r)" ]; then
    echo "======================================================="
    echo "[ALERTA CRÍTICA] El kernel de Arch Linux se actualizó."
    echo "Los controladores lógicos de red para Docker se han borrado."
    echo "Por seguridad, ejecuta un reinicio rápido del servidor:"
    echo "                 'sudo reboot'"
    echo "Y vuelve a lanzar este script. El despliegue continuará."
    echo "======================================================="
    exit 0
fi

echo "--> Dependencias del sistema validadas con éxito."
echo ""

echo "======================================================="
echo "=== PASO 2: ASIGNACIÓN DE DISCO Y ESPACIO DINÁMICO  ==="
echo "======================================================="

echo "Puntos de montaje activos detectados en tu Arch Linux:"
echo "-----------------------------------------------------------------------"
df -h -x tmpfs -x devtmpfs -x run | grep -E '^/dev/' || df -h
echo "-----------------------------------------------------------------------"
echo ""

# Bucle interactivo con validación estricta de rutas de almacenamiento
set +e
while true; do
    read -p "Introduce la ruta absoluta del punto de montaje para LanCache (ej. /mnt/disco2 o /): " USER_PATH
    
    if [[ -z "$USER_PATH" ]] || [[ ! "$USER_PATH" =~ ^/ ]]; then
        echo "Error: Debes introducir una ruta absoluta que comience por '/'."
        continue
    fi
    
    if [ -d "$USER_PATH" ]; then
        BASE_DIR=$(realpath "$USER_PATH")
        break
    else
        echo "Error: La ruta '$USER_PATH' no existe en el sistema o no está montada."
    fi
done
set -e

# Cálculo matemático dinámico del almacenamiento seguro (Margen de protección de 15GB)
FREE_KB=$(df -k "$BASE_DIR" | awk 'NR==2 {print $4}')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))

if [ "$FREE_GB" -le 25 ]; then
    echo "¡Error fatal!: Almacenamiento insuficiente en el disco (${FREE_GB}GB). LanCache requiere al menos 25GB libres."
    exit 1
fi

CACHE_DISK_SIZE="$(( FREE_GB - 15 ))g"
echo "--> Almacenamiento libre calculado: ${FREE_GB} GB."
echo "--> Tamaño máximo asignado para la caché de juegos: ${CACHE_DISK_SIZE}"

DATA_DIR="${BASE_DIR}/lancache/data"
LOG_DIR="${BASE_DIR}/lancache/logs"

# Permisos abiertos controlados para mitigar bloqueos de fstab externos con Docker
sudo mkdir -p "$DATA_DIR" "$LOG_DIR"
sudo chmod 777 "${BASE_DIR}/lancache"
sudo chmod -R 777 "$DATA_DIR" "$LOG_DIR"

echo ""
echo "======================================================="
echo "=== PASO 3: CONTROL DE INTERFACES Y BLINDAJE DE RED  ==="
echo "======================================================="

INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)

if [ -z "$INTERFACE" ] || [ -z "$GATEWAY" ]; then
    echo "¡Error crítico!: La máquina no dispone de una interfaz de red activa conectada a Internet."
    exit 1
fi

# Desvincular cualquier archivo previo para evitar enlaces rotos de systemd-resolved
sudo rm -f /etc/resolv.conf

# BLINDAJE DE RESOLUCIÓN INTERNA: Forzar DNS estables de producción en el host
echo "--> Configurando servidores de nombres raíz temporales..."
cat <<EOF | sudo tee /etc/resolv.conf > /dev/null
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# DESACTIVAR TOTALMENTE systemd-resolved para liberar el puerto 53 en todas las IPs locales
if systemctl is-active --quiet systemd-resolved.service || systemctl is-enabled --quiet systemd-resolved.service; then
    echo "--> Deteniendo y liberando puerto 53 de systemd-resolved..."
    sudo systemctl stop systemd-resolved.service || true
    sudo systemctl disable systemd-resolved.service || true
fi

# Levantar alias virtual secundario para la IP de LanCache (Protección SSH anti-desconexión masiva)
echo "--> Asignando alias virtual a la interfaz principal (${LANCACHE_IP})..."
sudo ip addr add ${LANCACHE_IP}/24 dev "$INTERFACE" label "${INTERFACE}:lancache" 2>/dev/null || true

echo "--> Arrancando e inicializando el motor de Docker..."
sudo systemctl enable --now containerd.service
sudo systemctl enable --now docker.service
sudo systemctl restart docker.service

sudo mkdir -p /opt/lancache-docker
cd /opt/lancache-docker

echo ""
echo "======================================================="
echo "=== PASO 4: CREACIÓN DE INFRAESTRUCTURA LANCACHE    ==="
echo "======================================================="

# Generar docker-compose.yml nativo con especificación moderna V2
sudo tee docker-compose.yml > /dev/null <<EOF
services:
  dns:
    image: lancachenet/lancache-dns:latest
    container_name: lancache-dns
    env_file: .env
    restart: always
    ports:
      - "${LANCACHE_IP}:53:53/udp"
      - "${LANCACHE_IP}:53:53/tcp"

  sniproxy:
    image: lancachenet/sniproxy:latest
    container_name: lancache-sniproxy
    env_file: .env
    restart: always
    ports:
      - "${LANCACHE_IP}:443:443/tcp"

  monolithic:
    image: lancachenet/monolithic:latest
    container_name: lancache-monolithic
    env_file: .env
    restart: always
    ports:
      - "${LANCACHE_IP}:80:80/tcp"
    volumes:
      - ${DATA_DIR}:/data/cache
      - ${LOG_DIR}:/data/logs
EOF

# Generar archivo .env con variables de bind obligatorias para el DNS
sudo tee .env > /dev/null <<EOF
LANCACHE_IP=${LANCACHE_IP}
DNS_BIND_IP=${LANCACHE_IP}
UPSTREAM_DNS=1.1.1.1 8.8.8.8
CACHE_DISK_SIZE=${CACHE_DISK_SIZE}
CACHE_INDEX_SIZE=250m
CACHE_MAX_AGE=3650d
TZ=Europe/Madrid
EOF

echo ""
echo "======================================================="
echo "=== PASO 5: DESPLIEGUE EN VIVO Y DESCARGA           ==="
echo "======================================================="

# Comando de orquestación moderno
sudo docker compose up -d
echo "--> Infraestructura de contenedores desplegada correctamente."

echo ""
echo "======================================================="
echo "=== PASO 6: CONFIGURACIÓN PERSISTENTE DE IP EN ARCH ==="
echo "======================================================="

if systemctl is-active --quiet NetworkManager.service; then
    echo "--> Aplicando configuración estática permanente en NetworkManager..."
    NM_CONN=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":${INTERFACE}$" | cut -d: -f1 | head -n1)
    if [ -n "$NM_CONN" ]; then
        sudo nmcli connection modify "$NM_CONN" ipv4.addresses "${LANCACHE_IP}/24"
        sudo nmcli connection modify "$NM_CONN" ipv4.gateway "$GATEWAY"
        sudo nmcli connection modify "$NM_CONN" ipv4.dns "1.1.1.1 8.8.8.8"
        sudo nmcli connection modify "$NM_CONN" ipv4.method manual
        echo "--> Configuración grabada en perfiles de NetworkManager."
    fi
else
    # Red nativa para Arch Linux simple
    echo "--> Forzando configuración estática robusta en la arquitectura systemd-networkd..."
    sudo mkdir -p /etc/systemd/network
    sudo tee "/etc/systemd/network/10-lancache-static.network" > /dev/null <<EOF
[Match]
Name=${INTERFACE}

[Network]
Address=${LANCACHE_IP}/24
Gateway=${GATEWAY}
DNS=1.1.1.1 8.8.8.8
EOF
    
    # Apagar clientes DHCP antiguos que intenten pisar la red tras reiniciar
    sudo systemctl stop dhcpcd.service > /dev/null 2>&1 || true
    sudo systemctl disable dhcpcd.service > /dev/null 2>&1 || true
    
    sudo systemctl enable systemd-networkd.service > /dev/null 2>&1
    
    # Indicar a openresolv de forma nativa que no modifique el archivo resolv.conf bajo ningún concepto
    echo "--> Bloqueando modificaciones de red sobre resolv.conf mediante openresolv..."
    sudo mkdir -p /etc
    sudo tee /etc/resolvconf.conf > /dev/null <<EOF
# Configurado por LanCache Script
resolvconf=NO
EOF
    
    # Escribir el archivo estático definitivo accesible para Docker
    sudo rm -f /etc/resolv.conf
    cat <<EOF | sudo tee /etc/resolv.conf > /dev/null
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    echo "--> Configuración estática y enrutamiento DNS completados de forma nativa."
fi

echo ""
echo "======================================================="
echo "===       ¡INSTALACIÓN COMPLETADA CON ÉXITO!        ==="
echo "======================================================="
echo " Servidor LanCache configurado en: ${LANCACHE_IP}"
echo " Tamaño de almacenamiento asignado: ${CACHE_DISK_SIZE}"
echo " Carpeta de administración: /opt/lancache-docker"
echo " Almacenamiento físico de descargas: ${DATA_DIR}"
echo "-------------------------------------------------------"
echo " IMPORTANTE: Para aplicar todos los cambios de la red"
echo " estática de forma limpia y definitiva, debes reiniciar:"
echo "                 'sudo reboot'"
echo "======================================================="
