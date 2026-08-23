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

# 2. Extraer dinámicamente las rutas de almacenamiento del instalador principal
echo "--> Detectando rutas de almacenamiento previas..."

# Extraer de forma segura la ruta real de datos (/data/cache)
DATA_DIR=$(grep -A 10 "monolithic:" docker-compose.yml | grep "/data/cache" | awk -F':' '{print $1}' | awk '{print $2}')
# Extraer de forma segura la ruta real de logs (/data/logs)
LOG_DIR=$(grep -A 10 "monolithic:" docker-compose.yml | grep "/data/logs" | awk -F':' '{print $1}' | awk '{print $2}')

if [ -z "$DATA_DIR" ] || [ ! -d "$DATA_DIR" ]; then
    echo "¡Error crítico!: No se pudo determinar el directorio de datos o la carpeta no existe."
    exit 1
fi

if [ -z "$LOG_DIR" ] || [ ! -d "$LOG_DIR" ]; then
    echo "¡Error crítico!: No se pudo determinar el directorio de logs o la carpeta no existe."
    exit 1
fi

echo "--> Carpeta de datos detectada en: $DATA_DIR"
echo "--> Carpeta de logs detectada en: $LOG_DIR"

# 3. Modificar el archivo docker-compose.yml para inyectar el contenedor de la GUI
echo "--> Integrando contenedor Lancache-Dashboard en la infraestructura existente..."

# Crear una copia de seguridad por seguridad antes de modificar
sudo cp docker-compose.yml docker-compose.yml.bak

# Reescritura limpia inyectando las rutas reales detectadas como cadenas absolutas
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
      - "${DATA_DIR}:/data/cache"
      - "${LOG_DIR}:/data/logs"

  dashboard:
    image: lancachenet/lancache-dashboard:latest
    container_name: lancache-dashboard
    restart: always
    ports:
      - "${LANCACHE_IP}:8080:80/tcp"
    environment:
      - TZ=Europe/Madrid
    volumes:
      - "${LOG_DIR}:/var/log/nginx"
EOF

# Validar la sintaxis del archivo generado antes de romper nada
if ! sudo docker compose config > /dev/null 2>&1; then
    echo "¡Error crítico!: La sintaxis del archivo docker-compose generado es incorrecta."
    echo "Restaurando copia de seguridad..."
    sudo cp docker-compose.yml.bak docker-compose.yml
    exit 1
fi

echo "--> Archivo de configuración actualizado y validado con éxito."
echo ""

echo "======================================================="
echo "=== PASO 2: REINICIANDO Y DESPLEGANDO LA INTERFAZ   ==="
echo "======================================================="

# Descargar la imagen del dashboard de forma explícita
echo "--> Descargando imagen del panel gráfico..."
sudo docker compose pull dashboard

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
