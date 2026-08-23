#!/bin/bash
# Evitar ejecuciones sin privilegios de root
if [ "$EUID" -ne 0 ]; then
  echo "Por favor, ejecuta este script como root (sudo)."
  exit 1
fi

# =====================================================================
# CONFIGURACIÓN FIJA DE RED Y ENTORNO
# =====================================================================
LANCACHE_IP="192.168.0.20"
UPSTREAM_DNS="1.1.1.1"
TIMEZONE="Europe/Madrid"

echo "======================================================="
echo "=== PASO 1: INSTALACIÓN DE DEPENDENCIAS (ARCH)      ==="
echo "======================================================="
pacman -Syu --noconfirm
pacman -S --needed --noconfirm docker docker-compose git
systemctl enable --now docker.service

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

# Definición de subdirectorios bajo el punto de montaje seleccionado
LANCACHE_ROOT="${BASE_DIR}/lancache"
DATA_DIR="${LANCACHE_ROOT}/data"
LOG_DIR="${LANCACHE_ROOT}/logs"

# Permisos abiertos controlados para mitigar bloqueos con Docker
mkdir -p "$DATA_DIR" "$LOG_DIR"
touch "${LOG_DIR}/access.log"
chmod 777 "$LANCACHE_ROOT"
chmod -R 777 "$DATA_DIR" "$LOG_DIR"

cd "$LANCACHE_ROOT"

echo "======================================================="
echo "=== PASO 3: GENERANDO ARCHIVO DOCKER-COMPOSE        ==="
echo "======================================================="
cat << 'EOF' > docker-compose.yml
version: '3.8'

services:
  # Servidor DNS de LanCache
  lancache-dns:
    image: lancachenet/lancache-dns:latest
    container_name: lancache-dns
    env_file: .env
    ports:
      - "192.168.0.20:53:53/udp"
      - "192.168.0.20:53:53/tcp"
    restart: unless-stopped

  # Servidor Caché monolítico
  lancache:
    image: lancachenet/monolithic:latest
    container_name: lancache
    env_file: .env
    ports:
      - "192.168.0.20:80:80"
      - "192.168.0.20:443:443"
    volumes:
      - ./data:/data/cache
      - ./logs:/data/logs
    restart: unless-stopped

  # Backend de DeveLanCacheUI (Procesador de logs)
  develancacheui-backend:
    image: devedse/develancacheui_backend:latest
    container_name: develancacheui-backend
    ports:
      - "192.168.0.20:5000:8080"
    volumes:
      - ./logs:/app/lancachelogs
    environment:
      - TZ=${TIMEZONE}
    restart: unless-stopped
    depends_on:
      - lancache

  # Frontend de DeveLanCacheUI (Panel Visual Web)
  develancacheui-frontend:
    image: devedse/develancacheui_frontend:latest
    container_name: develancacheui-frontend
    ports:
      - "192.168.0.20:8080:80"
    environment:
      - TZ=${TIMEZONE}
    restart: unless-stopped
    depends_on:
      - develancacheui-backend
EOF

echo "======================================================="
echo "=== PASO 4: GENERANDO VARIABLES DE ENTORNO (.ENV)    ==="
echo "======================================================="
cat << EOF > .env
# Configuración de red fija
LANCACHE_IP=${LANCACHE_IP}
DNS_BIND_IP=${LANCACHE_IP}
UPSTREAM_DNS=${UPSTREAM_DNS}
WHITELIST_DNS=${UPSTREAM_DNS}

# Parámetros dinámicos de almacenamiento calculados
CACHE_DISK_SIZE=${CACHE_DISK_SIZE}
CACHE_MAX_AGE=3650d
CACHE_INDEX_SIZE=500m

# Ajustes del sistema
TZ=${TIMEZONE}
EOF

echo "======================================================="
echo "=== PASO 5: DESPLEGANDO CONTENEDORES EN DOCKER      ==="
echo "======================================================="
docker compose up -d

echo "========================================================="
echo " ¡Instalación dinámica completada con éxito!"
echo "========================================================="
echo " -> Directorio de instalación: ${LANCACHE_ROOT}"
echo " -> Espacio asignado a la caché: ${CACHE_DISK_SIZE}"
echo " -> Servidor LanCache en IP: ${LANCACHE_IP}"
echo " -> Acceso a la GUI Web: http://${LANCACHE_IP}:8080"
echo " -> Cambia el DNS de tus clientes a: ${LANCACHE_IP}"
echo "========================================================="
