#!/usr/bin/env bash

# Salir inmediatamente si un comando falla de forma imprevista
set -e

# Configuración de la IP asignada por DHCP estático en el Router para el Servidor
LANCACHE_IP="192.168.0.20"

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
    docker-compose \
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
GUI_BACKEND_DIR="${BASE_DIR}/lancache/gui_backend"

# Permisos abiertos controlados para mitigar bloqueos con Docker
sudo mkdir -p "$DATA_DIR" "$LOG_DIR" "$GUI_BACKEND_DIR"
sudo chmod 777 "${BASE_DIR}/lancache"
sudo chmod -R 777 "$DATA_DIR" "$LOG_DIR" "$GUI_BACKEND_DIR"

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

# CORREGIDO: Eliminado el binding explícito de IP en los puertos para permitir respuestas de red correctas (0.0.0.0 nativo de Docker)
sudo tee docker-compose.yml > /dev/null <<EOF
services:
  dns:
    image: lancachenet/lancache-dns:latest
    container_name: lancache-dns
    env_file: .env
    restart: always
    ports:
      - "53:53/udp"
      - "53:53/tcp"

  sniproxy:
    image: lancachenet/sniproxy:latest
    container_name: lancache-sniproxy
    env_file: .env
    restart: always
    ports:
      - "443:443/tcp"

  monolithic:
    image: lancachenet/monolithic:latest
    container_name: lancache-monolithic
    env_file: .env
    restart: always
    ports:
      - "80:80/tcp"
    volumes:
      - ${DATA_DIR}:/data/cache
      - ${LOG_DIR}:/data/logs

  develancacheui_backend:
    image: devedse/develancacheui_backend:latest
    container_name: develancacheui-backend
    restart: unless-stopped
    ports:
      - "7301:80"
    environment:
      - TZ=Europe/Madrid
      - LANG=en_GB.UTF-8
    volumes:
      - "${GUI_BACKEND_DIR}:/var/develancacheuidata"
      - "${LOG_DIR}:/var/develancacheui/lancachelogs:ro"
    dns:
      - 1.1.1.1

  develancacheui_frontend:
    image: devedse/develancacheui_frontend:latest
    container_name: develancacheui-frontend
    restart: unless-stopped
    ports:
      - "7302:80"
    environment:
      - BACKENDURL=http://${LANCACHE_IP}:7301
      - AllowedHosts=*
EOF

# CORREGIDO: DNS_BIND_IP ahora apunta correctamente a la IP física del LanCache para mapear las descargas de los clientes hacia Nginx
sudo tee .env > /dev/null <<EOF
LANCACHE_IP=${LANCACHE_IP}
DNS_BIND_IP=${LANCACHE_IP}
UPSTREAM_DNS=1.1.1.1
CACHE_DISK_SIZE=${CACHE_DISK_SIZE}
CACHE_INDEX_SIZE=250m
CACHE_MAX_AGE=3650d
TZ=Europe/Madrid
EOF

echo ""
echo "======================================================="
echo "=== PASO 5: DESPLIEGUE EN VIVO Y DESCARGA           ==="
echo "======================================================="

# Descargar y levantar la infraestructura de contenedores
sudo docker-compose pull
sudo docker-compose up -d
echo "--> Infraestructura de contenedores desplegada correctamente."

echo ""
echo "======================================================="
echo "=== PASO 6: CONFIGURACIÓN DE RESOLUCIÓN LOCAL       ==="
echo "======================================================="

# Evitar que openresolv destruya el resolv.conf en el futuro
sudo mkdir -p /etc
sudo tee /etc/resolvconf.conf > /dev/null <<EOF
resolvconf=NO
EOF

# Apuntar el host a su IP física ($LANCACHE_IP)
sudo rm -f /etc/resolv.conf
cat <<EOF | sudo tee /etc/resolv.conf > /dev/null
nameserver ${LANCACHE_IP}
nameserver 1.1.1.1
EOF

echo ""
echo "======================================================="
echo "===       ¡INSTALACIÓN COMPLETADA CON ÉXITO!        ==="
echo "======================================================="
echo " Tu servidor asume la IP asignada por Router: ${LANCACHE_IP}"
echo " Acceso a la nueva GUI Web: http://${LANCACHE_IP}:7302"
echo " Tamaño de almacenamiento asignado: ${CACHE_DISK_SIZE}"
echo " Carpeta de administración: /opt/lancache-docker"
echo "-------------------------------------------------------"
echo " REQUISITO EN WINDOWS 11:"
echo " Para obligar a Windows a usar IPv4 en Steam, crea el"
echo " archivo 'steam.cfg' en la carpeta de Steam con:"
echo " @NoWebRequestsIPv6 1"
echo "-------------------------------------------------------"
echo " Ejecuta el reinicio definitivo ahora mismo:"
echo "                 'sudo reboot'"
echo "======================================================="
