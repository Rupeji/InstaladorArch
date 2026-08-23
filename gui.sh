#!/usr/bin/env bash

# Salir inmediatamente si un comando falla de forma imprevista
set -e

# Configuración de la IP fija global para el Servidor y LanCache
LANCACHE_IP="192.168.0.7"

echo "======================================================="
echo "=== PASO 1: INSTALACIÓN DE DEPENDENCIAS DEL SISTEMA ==="
echo "======================================================="

# Guardar la versión del kernel antes de actualizar para prevenir colapso de módulos de Docker
KERNEL_ANTES=$(uname -r)

echo "--> Actualizando el sistema completo de Arch Linux (Pacman -Syu)..."
sudo pacman -Syu --noconfirm

echo "--> Instalando dependencias estructurales y binarios de red..."
sudo pacman -S --needed --noconfirm \
    docker \
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

# Uso de '--output=avail' para garantizar una salida numérica limpia en una sola línea
FREE_KB=$(df -k --output=avail "$BASE_DIR" | tail -n1 | tr -d ' ')
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

# Detectar la interfaz física real conectada y su puerta de enlace (Gateway) actual
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)

if [ -z "$INTERFACE" ] || [ -z "$GATEWAY" ]; then
    echo "¡Error crítico!: La máquina no dispone de una interfaz de red activa conectada a Internet."
    exit 1
fi

# Desvincular cualquier archivo previo para evitar enlaces rotos de systemd-resolved
sudo rm -f /etc/resolv.conf

# Configurar servidores DNS temporales para que Docker pueda descargar las imágenes sin problemas
echo "--> Configurando servidores de nombres raíz temporales..."
cat <<EOF | sudo tee /etc/resolv.conf > /dev/null
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# DESACTIVAR TOTALMENTE systemd-resolved para liberar el puerto 53 en el host
if systemctl is-active --quiet systemd-resolved.service || systemctl is-enabled --quiet systemd-resolved.service; then
    echo "--> Deteniendo y liberando puerto 53 de systemd-resolved..."
    sudo systemctl stop systemd-resolved.service || true
    sudo systemctl disable systemd-resolved.service || true
fi

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

# Generar docker-compose.yml mapeado de forma nativa a la IP estática definitiva
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

  dashboard:
    image: imahmud1/lancache-dashboard:latest
    container_name: lancache-dashboard
    env_file: .env
    restart: always
    ports:
      - "${LANCACHE_IP}:8080:3000/tcp"
    volumes:
      - ${LOG_DIR}:/lancache/logs:ro
EOF

# Generar archivo .env
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

# Descargar y levantar la estructura (Escucharán temporalmente hasta el reinicio de red)
sudo docker compose up -d
echo "--> Infraestructura de contenedores desplegada correctamente."

echo ""
echo "======================================================="
echo "=== PASO 6: CONFIGURACIÓN PERSISTENTE DE IP EN ARCH ==="
echo "======================================================="

# Forzar de manera definitiva que la IP principal de ESTA máquina sea la 192.168.0.7
if systemctl is-active --quiet NetworkManager.service; then
    echo "--> Aplicando IP estática fija 192.168.0.7 en NetworkManager..."
    NM_CONN=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":${INTERFACE}$" | cut -d: -f1 | head -n1)
    if [ -n "$NM_CONN" ]; then
        sudo nmcli connection modify "$NM_CONN" ipv4.addresses "${LANCACHE_IP}/24"
        sudo nmcli connection modify "$NM_CONN" ipv4.gateway "$GATEWAY"
        sudo nmcli connection modify "$NM_CONN" ipv4.dns "1.1.1.1 8.8.8.8"
        sudo nmcli connection modify "$NM_CONN" ipv4.method manual
        echo "--> Configuración grabada. La IP del servidor cambiará al reiniciar."
    fi
else
    echo "--> Configurando IP estática fija 192.168.0.7 en systemd-networkd..."
    sudo mkdir -p /etc/systemd/network
    
    # Se sobrescribe el adaptador para que la IP del propio sistema operativo sea de verdad la .7
    sudo tee "/etc/systemd/network/10-lancache-static.network" > /dev/null <<EOF
[Match]
Name=${INTERFACE}

[Network]
Address=${LANCACHE_IP}/24
Gateway=${GATEWAY}
DNS=1.1.1.1 8.8.8.8
EOF
    
    sudo systemctl stop dhcpcd.service > /dev/null 2>&1 || true
    sudo systemctl disable dhcpcd.service > /dev/null 2>&1 || true
    sudo systemctl enable systemd-networkd.service > /dev/null 2>&1
    
    # Evitar que openresolv destruya el resolv.conf
    sudo mkdir -p /etc
    sudo tee /etc/resolvconf.conf > /dev/null <<EOF
# Configurado por LanCache Script
resolvconf=NO
EOF
    
    sudo rm -f /etc/resolv.conf
    cat <<EOF | sudo tee /etc/resolv.conf > /dev/null
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    echo "--> Configuración de red estática completada."
fi

echo ""
echo "======================================================="
echo "===       ¡INSTALACIÓN COMPLETADA CON ÉXITO!        ==="
echo "======================================================="
echo " Tu servidor Arch Linux ahora se fijará en: ${LANCACHE_IP}"
echo " Acceso al Dashboard desde tu red: http://${LANCACHE_IP}:8080"
echo " Tamaño de almacenamiento asignado: ${CACHE_DISK_SIZE}"
echo " Carpeta de administración: /opt/lancache-docker"
echo "-------------------------------------------------------"
echo " ¡¡ATENCIÓN PREVIO AL REINICIO!!:"
echo " Al reiniciar, perderás tu IP actual de SSH."
echo " Deberás volver a conectarte usando la nueva IP:"
echo "                 ssh usuario@192.168.0.7"
echo ""
echo " Ejecuta el reinicio definitivo ahora mismo:"
echo "                 'sudo reboot'"
echo "======================================================="
