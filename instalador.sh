#!/usr/bin/env bash

# Salir inmediatamente si un comando falla
set -e

# Configuración de variables fijas
LANCACHE_IP="192.168.0.7"

echo "======================================================="
echo "=== PASO 1: INSTALACIÓN DE DEPENDENCIAS DEL SISTEMA ==="
echo "======================================================="

# Actualizar repositorios e instalar paquetes base necesarios
echo "--> Actualizando repositorios de Pacman..."
sudo pacman -Sy

echo "--> Instalando dependencias necesarias (docker, network utilities, coreutils)..."
sudo pacman -S --needed --noconfirm \
    docker \
    docker-compose \
    git \
    coreutils \
    glibc \
    iptables-nft \
    util-linux \
    gawk

echo "--> Dependencias instaladas correctamente."
echo ""

echo "======================================================="
echo "=== PASO 2: SELECCIÓN DEL DISCO Y ESPACIO DINÁMICO  ==="
echo "======================================================="

# Mostrar puntos de montaje reales
echo "Puntos de montaje disponibles en tu sistema Arch Linux:"
echo "-----------------------------------------------------------------------"
df -h -x tmpfs -x devtmpfs -x run | grep -E '^/dev/' || df -h
echo "-----------------------------------------------------------------------"
echo ""

# Bucle interactivo para la ruta de montaje
set +e
while true; do
    read -p "Introduce la ruta absoluta del punto de montaje para LanCache (ej. /mnt/disco2 o /): " USER_PATH
    
    if [[ -z "$USER_PATH" ]] || [[ ! "$USER_PATH" =~ ^/ ]]; then
        echo "Error: Introduce una ruta absoluta válida que empiece por '/'."
        continue
    fi
    
    if [ -d "$USER_PATH" ]; then
        BASE_DIR=$(realpath "$USER_PATH")
        break
    else
        echo "Error: La ruta '$USER_PATH' no existe o no está montada. Inténtalo de nuevo."
    fi
done
set -e

# --- CÁLCULO DINÁMICO DEL ESPACIO LIBRE (Margen seguro de 5 GB) ---
FREE_KB=$(df -k "$BASE_DIR" | awk 'NR==2 {print $4}')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))

if [ "$FREE_GB" -le 10 ]; then
    echo "¡Error crítico!: Solo quedan ${FREE_GB}GB libres en este disco. LanCache necesita más espacio."
    exit 1
fi

CACHE_DISK_SIZE="$(( FREE_GB - 5 ))g"
echo "--> Espacio libre total detectado: ${FREE_GB} GB."
echo "--> Tamaño configurado para LanCache (dejando 5GB libres para el sistema): ${CACHE_DISK_SIZE}"

DATA_DIR="${BASE_DIR}/lancache/data"
LOG_DIR="${BASE_DIR}/lancache/logs"

sudo mkdir -p "$DATA_DIR" "$LOG_DIR"
sudo chown -R root:root "${BASE_DIR}/lancache"
sudo chmod -R 755 "${BASE_DIR}/lancache"

echo ""
echo "======================================================="
echo "=== PASO 3: CONFIGURACIÓN DEL SISTEMA Y SERVICIOS   ==="
echo "======================================================="

echo "--> Activando e iniciando el servicio Docker..."
sudo systemctl enable --now docker.service
sudo systemctl restart docker.service

mkdir -p ~/lancache-docker
cd ~/lancache-docker

echo ""
echo "======================================================="
echo "=== PASO 4: CONFIGURACIÓN DE CONTENEDORES LANCACHE  ==="
echo "======================================================="

# Generar docker-compose.yml
cat <<EOF > docker-compose.yml
version: '2'

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

# Generar archivo .env con el tamaño dinámico calculado
cat <<EOF > .env
LANCACHE_IP=${LANCACHE_IP}
UPSTREAM_DNS=1.1.1.1 8.8.8.8
CACHE_DISK_SIZE=${CACHE_DISK_SIZE}
CACHE_INDEX_SIZE=250m
CACHE_MAX_AGE=3650d
TZ=Europe/Madrid
EOF

echo ""
echo "======================================================="
echo "=== PASO 5: DESPLIEGUE DE LANCACHE                  ==="
echo "======================================================="

sudo docker-compose up -d
echo "--> Contenedores inicializados."

echo ""
echo "======================================================="
echo "=== PASO 6: CONFIGURACIÓN DE IP ESTÁTICA EN SEGUNDO PLANO ==="
echo "======================================================="

# Identificar la interfaz de red primaria por defecto conectada a internet
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
# Identificar la puerta de enlace actual (Gateway)
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)

if [ -z "$INTERFACE" ] || [ -z "$GATEWAY" ]; then
    echo "[AVISO] No se pudo determinar la interfaz o el gateway de internet de forma automática."
    echo "Saltando configuración automatizada de red para no romper el script."
else
    echo "--> Detectada interfaz activa: $INTERFACE (Puerta de enlace: $GATEWAY)"
    
    # 1. Escenario si se está usando NetworkManager
    if systemctl is-active --quiet NetworkManager.service; then
        echo "--> Detectado NetworkManager activo. Configurando IP fija de fondo..."
        # Obtener el nombre de la conexión activa de NetworkManager
        NM_CONN=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":${INTERFACE}$" | cut -d: -f1 | head -n1)
        
        if [ -n "$NM_CONN" ]; then
            sudo nmcli connection modify "$NM_CONN" ipv4.addresses "${LANCACHE_IP}/24"
            sudo nmcli connection modify "$NM_CONN" ipv4.gateway "$GATEWAY"
            sudo nmcli connection modify "$NM_CONN" ipv4.dns "1.1.1.1 8.8.8.8"
            sudo nmcli connection modify "$NM_CONN" ipv4.method manual
            echo "--> ¡NetworkManager reconfigurado! Se aplicará de forma fija en el próximo inicio."
        else
            echo "[AVISO] No se encontró perfil nmcli explícito para $INTERFACE. Red estática omitida."
        fi

    # 2. Escenario si se está usando systemd-networkd
    elif systemctl is-active --quiet systemd-networkd.service || [ ! -f /etc/NetworkManager/NetworkManager.conf ]; then
        echo "--> Configurando a través de systemd-networkd..."
        # Escribir la configuración sin alterar el estado actual del adaptador
        sudo mkdir -p /etc/systemd/network
        sudo cat <<EOF | sudo tee "/etc/systemd/network/10-lancache-static.network" > /dev/null
[Match]
Name=${INTERFACE}

[Network]
Address=${LANCACHE_IP}/24
Gateway=${GATEWAY}
DNS=1.1.1.1 8.8.8.8
EOF
        sudo systemctl enable systemd-networkd.service > /dev/null 2>&1
        echo "--> Archivo de configuración estática para systemd-networkd guardado."
    fi
fi

echo ""
echo "======================================================="
echo "===       ¡INSTALACIÓN COMPLETADA CON ÉXITO!        ==="
echo "======================================================="
echo " LanCache está corriendo en la IP: ${LANCACHE_IP}"
echo " Tamaño máximo de caché asignado: ${CACHE_DISK_SIZE}"
echo " Ruta de almacenamiento de juegos: ${DATA_DIR}"
echo "-------------------------------------------------------"
echo " IMPORTANTE: La IP estática ha quedado configurada de"
echo " forma permanente para persistir tras los reinicios."
echo " Para aplicarla ahora mismo sin reiniciar puedes ejecutar:"
echo " 'sudo systemctl restart NetworkManager' o 'sudo networkctl reload'"
echo "======================================================="
