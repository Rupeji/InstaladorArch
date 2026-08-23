#!/usr/bin/env bash

# Salir inmediatamente si un comando falla
set -e

# Configuración de variables fijas compatibles con el script anterior
LANCACHE_IP="192.168.0.7"
PROJECT_DIR="/opt/lancache-docker"

echo "======================================================="
echo "=== INICIANDO INSTALACIÓN DE INTERFAZ GRÁFICA (GUI) ==="
echo "======================================================="

# 1. Verificar si existe la instalación previa de LanCache
if [ ! -d "$PROJECT_DIR" ] || [ ! -f "$PROJECT_DIR/docker-compose.yml" ]; then
    echo "¡Error crítico!: No se encontró la carpeta o el archivo docker-compose en $PROJECT_DIR."
    echo "Por favor, ejecuta primero el script de instalación de LanCache."
    exit 1
fi

cd "$PROJECT_DIR"

# 2. Extraer dinámicamente la ruta de logs elegida en el script anterior
echo "--> Detectando rutas de almacenamiento previas..."
LOG_DIR=$(grep -A 10 "monolithic:" docker-compose.yml | grep "/data/logs" | awk -F':' '{print $1}' | awk '{print $2}')

if [ -z "$LOG_DIR" ] || [ ! -d "$LOG_DIR" ]; then
    echo "¡Error crítico!: No se pudo determinar el directorio de logs o la carpeta no existe."
    exit 1
fi
echo "--> Carpeta de logs detectada correctamente en: $LOG_DIR"

# 3. Modificar el archivo docker-compose.yml para inyectar el contenedor de la GUI
echo "--> Integrando contenedor Lancache-Dashboard en la infraestructura existente..."

# Crear una copia de seguridad por seguridad antes de modificar
sudo cp docker-compose.yml docker-compose.yml.bak

# Reescritura limpia añadiendo el servicio del panel gráfico
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
      - \${DATA_DIR}:/data/cache
      - ${LOG_DIR}:/data/logs

  dashboard:
    image: lancachenet/lancache-dashboard:latest
    container_name: lancache-dashboard
    restart: always
    ports:
      - "${LANCACHE_IP}:8080:80/tcp"
    environment:
      - TZ=Europe/Madrid
    volumes:
      - ${LOG_DIR}:/var/log/nginx
EOF

echo "--> Archivo de configuración actualizado con éxito."
echo ""

echo "======================================================="
echo "=== PASO 2: REINICIANDO Y DESPLEGANDO LA INTERFAZ   ==="
echo "======================================================="

# Actualizar el despliegue con la nueva GUI instalada
echo "--> Recreando la pila de Docker con el nuevo panel integrado..."
sudo docker compose up -d --remove-orphans

echo ""
echo "======================================================="
echo "===       ¡GUI INSTALADA CORRECTAMENTE!             ==="
echo "======================================================="
echo " El panel gráfico está activo y analizando logs en vivo."
echo " Puedes acceder desde cualquier navegador de tu red en:"
echo " 👉 http://${LANCACHE_IP}:8080"
echo "======================================================="
