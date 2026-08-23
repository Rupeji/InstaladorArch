cat << 'EOF' > instalar_servidor_gaming.sh
#!/usr/bin/env bash

# Salir inmediatamente si un comando falla de forma imprevista
set -e

# Configuración de variables fijas solicitadas
LANCACHE_IP="192.168.0.7"
PIHOLE_PASS="TuContrasenaSegura123"

echo "======================================================="
echo "=== PASO 1: INSTALACIÓN DE DEPENDENCIAS DEL SISTEMA ==="
echo "======================================================="

KERNEL_ANTES=$(uname -r)

echo "--> Actualizando el sistema completo de Arch Linux (Pacman -Syu)..."
sudo pacman -Syu --noconfirm

echo "--> Instalando dependencias estructurales y binarios de red..."
sudo pacman -R --noconfirm openresolv || true
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
    bridge-utils \
    dnssec-anchors

KERNEL_AHORA=$(pacman -Q linux | awk '{print $2}' || echo "unknown")
if [[ "$KERNEL_ANTES" != *"$KERNEL_AHORA"* ]] && [ -d "/usr/lib/modules/$KERNEL_ANTES" ] && [ ! -d "/usr/lib/modules/$(uname -r)" ]; then
    echo "======================================================="
    echo "[ALERTA CRÍTICA] El kernel de Arch Linux se actualizó."
    echo "Los módulos de red para Docker se han borrado."
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

sudo mkdir -p "$DATA_DIR" "$LOG_DIR"
sudo chmod 777 "${BASE_DIR}/lancache"
sudo chmod -R 777 "$DATA_DIR" "$LOG_DIR"

sudo mkdir -p /etc/pihole /etc/dnsmasq.d
sudo chmod -R 777 /etc/pihole /etc/dnsmasq.d

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

sudo rm -f /etc/resolv.conf
cat <<EOF | sudo tee /etc/resolv.conf > /dev/null
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

if systemctl is-active --quiet systemd-resolved.service || systemctl is-enabled --quiet systemd-resolved.service; then
    echo "--> Configurando systemd-resolved en modo estático (Libera el puerto 53)..."
    sudo mkdir -p /etc/systemd/resolved.conf.d/
    sudo tee /etc/systemd/resolved.conf.d/lancache.conf > /dev/null <<EOF
[Resolve]
DNSStubListener=no
EOF
    sudo systemctl restart systemd-resolved.service
fi

sudo ip addr add ${LANCACHE_IP}/24 dev "$INTERFACE" label "${INTERFACE}:lancache" 2>/dev/null || true

echo "--> Arrancando e inicializando el motor de Docker..."
sudo systemctl enable --now containerd.service
sudo systemctl enable --now docker.service
sudo systemctl restart docker.service

sudo mkdir -p /opt/lancache-docker
cd /opt/lancache-docker

echo ""
echo "======================================================="
echo "=== PASO 4: CREACIÓN DE INFRAESTRUCTURA INTEGRADA   ==="
echo "======================================================="

sudo tee .env > /dev/null <<EOF
LANCACHE_IP=$LANCACHE_IP
DNS_BIND_IP=$LANCACHE_IP
UPSTREAM_DNS=172.25.0.100
CACHE_DISK_SIZE=$CACHE_DISK_SIZE
CACHE_INDEX_SIZE=250m
CACHE_MAX_AGE=3650d
TZ=Europe/Madrid
ENV_DATA_DIR=$DATA_DIR
ENV_LOG_DIR=$LOG_DIR
PIHOLE_PASS=$PIHOLE_PASS
EOF

sudo tee docker-compose.yml > /dev/null << 'EOF'
networks:
  lancache_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.25.0.0/24

services:
  dns:
    image: lancachenet/lancache-dns:latest
    container_name: lancache-dns
    env_file: .env
    restart: always
    ports:
      - "${LANCACHE_IP}:53:53/udp"
      - "${LANCACHE_IP}:53:53/tcp"
    networks:
      lancache_net:
        ipv4_address: 172.25.0.5

  sniproxy:
    image: lancachenet/sniproxy:latest
    container_name: lancache-sniproxy
    env_file: .env
    restart: always
    ports:
      - "${LANCACHE_IP}:443:443/tcp"
    networks:
      lancache_net:

  monolithic:
    image: lancachenet/monolithic:latest
    container_name: lancache-monolithic
    env_file: .env
    restart: always
    ports:
      - "${LANCACHE_IP}:80:80/tcp"
    volumes:
      - ${ENV_DATA_DIR}:/data/cache
      - ${ENV_LOG_DIR}:/data/logs
    networks:
      lancache_net:

  dashboard:
    image: lancachenet/lancache-dashboard:latest
    container_name: lancache-dashboard
    restart: always
    ports:
      - "${LANCACHE_IP}:8080:80/tcp"
    volumes:
      - ${ENV_LOG_DIR}:/var/log/nginx
    networks:
      lancache_net:

  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    restart: always
    ports:
      - "${LANCACHE_IP}:8081:80/tcp"
    environment:
      - TZ=Europe/Madrid
      - WEBPASSWORD=${PIHOLE_PASS}
      - PIHOLE_DNS_=1.1.1.1;8.8.8.8
      - DNSMASQ_USER=root
      - FT_SERVER=true
    volumes:
      - /etc/pihole:/etc/pihole
      - /etc/dnsmasq.d:/etc/dnsmasq.d
    networks:
      lancache_net:
        ipv4_address: 172.25.0.100
EOF

echo ""
echo "======================================================="
echo "=== PASO 5: DESPLIEGUE EN VIVO DE TODO EL ECOSISTEMA ==="
echo "======================================================="

sudo docker compose up -d --remove-orphans
echo "--> Todos los contenedores inicializados correctamente."

echo ""
echo "======================================================="
echo "=== PASO 6: CONFIGURACIÓN PERSISTENTE DE IP EN ARCH ==="
echo "======================================================="

if systemctl is-active --quiet NetworkManager.service; then
    echo "--> Aplicando configuración estática en NetworkManager..."
    NM_CONN=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":${INTERFACE}$" | cut -d: -f1 | head -n1)
    if [ -n "$NM_CONN" ]; then
        sudo nmcli connection modify "$NM_CONN" ipv4.addresses "${LANCACHE_IP}/24"
        sudo nmcli connection modify "$NM_CONN" ipv4.gateway "$GATEWAY"
        sudo nmcli connection modify "$NM_CONN" ipv4.dns "1.1.1.1 8.8.8.8"
        sudo nmcli connection modify "$NM_CONN" ipv4.method manual
    fi
else
    echo "--> Forzando configuración estática en systemd-networkd..."
    sudo mkdir -p /etc/systemd/network
    sudo tee "/etc/systemd/network/10-lancache-static.network" > /dev/null <<EOF
[Match]
Name=e*

[Network]
Address=${LANCACHE_IP}/24
Gateway=${GATEWAY}
DNS=1.1.1.1 8.8.8.8
EOF
    sudo systemctl stop dhcpcd.service > /dev/null 2>&1 || true
    sudo systemctl disable dhcpcd.service > /dev/null 2>&1 || true
    sudo systemctl enable systemd-networkd.service systemd-resolved.service > /dev/null 2>&1
    
    sudo mkdir -p /etc
    sudo tee /etc/resolvconf.conf > /dev/null <<EOF
resolvconf=NO
EOF
    sudo rm -f /etc/resolv.conf
    sudo ln -s /lib/systemd/resolv.conf /etc/resolv.conf
fi

echo "======================================================="
echo "===       ¡ENTORNO COMPLETADO CON ÉXITO!            ==="
echo "======================================================="
echo " Servidor Gaming unificado en la IP: ${LANCACHE_IP}"
echo " Panel LanCache (Juegos): http://${LANCACHE_IP}:8080"
echo " Panel Pi-hole (Anuncios): http://${LANCACHE_IP}:8081/admin"
echo " Contraseña Pi-hole: ${PIHOLE_PASS}"
echo " RECOMENDACIÓN: Ejecuta 'sudo reboot' ahora."
echo "======================================================="
EOF
chmod +x instalar_servidor_gaming.sh
echo "¡Archivo instalar_servidor_gaming.sh creado con éxito!"
