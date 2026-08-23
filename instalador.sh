#!/bin/bash

# Evitar que el script continúe si ocurre cualquier error imprevisto
set -e

echo "========================================================================="
echo "  INSTALADOR TODO EN UNO: LANCACHE + PI-HOLE + GESTIÓN DE DISCO (ARCH)   "
echo "========================================================================="

# =======================================================================
# 1. COMPROBACIÓN DE PRIVILEGIOS
# =======================================================================
if [ "$EUID" -ne 0 ]; then
    echo "[!] Este script necesita permisos de administrador (root)."
    if command -v sudo >/dev/null 2>&1; then
        echo "[-] Solicitando privilegios mediante sudo..."
        exec sudo "$0" "$@"
    else
        echo "[!] Error: No se detectó 'sudo'. Ejecútalo directamente como root."
        exit 1
    fi
fi

# ==========================================
# 2. VARIABLES DE CONFIGURACIÓN
# ==========================================
SERVER_IP="192.168.0.7"
NETMASK_SHORT="24"
GATEWAY="192.168.0.1"
DNS_PROVISIONAL="1.1.1.1"

PASSWORD_PIHOLE="TuContraseñaSegura123"
ZONA_HORARIA="Europe/Madrid"

# Punto de montaje e infraestructura
MOUNT_POINT="/mnt/lancache"
DIR_BASE="/opt/servicios"
PIHOLE_DATA="$DIR_BASE/pihole/config"
PIHOLE_DNSMASQ="$DIR_BASE/pihole/dnsmasq.d"

# =======================================================================
# 3. INSTALACIÓN DE DEPENDENCIAS SOLICITADAS
# =======================================================================
echo ""
echo "[-] Sincronizando repositorios e instalando paquetes requeridos..."
echo "--------------------------------------------------------------------------"
pacman -Sy --noconfirm
pacman -S --needed --noconfirm git curl util-linux docker docker-compose fastfetch nano openssh e2fsprogs

echo "[-] Activando servicios Docker y SSH..."
systemctl enable --now docker
systemctl enable --now sshd

# Permitir login de Root por SSH
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
if ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
fi
systemctl restart sshd

# =======================================================================
# 4. CONFIGURACIÓN DE RED ESTÁTICA AUTOMÁTICA
# =======================================================================
echo ""
echo "[-] Detectando interfaz de red primaria..."
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)

if [ -z "$INTERFACE" ]; then
    echo "[!] Error crítico: No se detectó ninguna tarjeta con salida a internet."
    exit 1
fi
echo "[+] Interfaz física activa: $INTERFACE"

if systemctl is-active --quiet NetworkManager; then
    echo "[+] Configurando IP fija mediante NetworkManager..."
    NM_CONN=$(nmcli -t -f DEVICE,NAME connection show --active | grep "^${INTERFACE}:" | cut -d: -f2 | head -n 1)
    if [ -n "$NM_CONN" ]; then
        nmcli connection modify "$NM_CONN" ipv4.addresses "$SERVER_IP/$NETMASK_SHORT"
        nmcli connection modify "$NM_CONN" ipv4.gateway "$GATEWAY"
        nmcli connection modify "$NM_CONN" ipv4.dns "$DNS_PROVISIONAL"
        nmcli connection modify "$NM_CONN" ipv4.method manual
        nmcli connection up "$NM_CONN"
    fi
elif systemctl is-active --quiet systemd-networkd; then
    echo "[+] Configurando IP fija mediante systemd-networkd..."
    NET_FILE="/etc/systemd/network/10-static-${INTERFACE}.network"
    cat <<EOF > "$NET_FILE"
[Match]
Name=$INTERFACE

[Network]
Address=$SERVER_IP/$NETMASK_SHORT
Gateway=$GATEWAY
DNS=$DNS_PROVISIONAL
EOF
    systemctl restart systemd-networkd
elif systemctl is-active --quiet dhcpcd; then
    echo "[+] Configurando IP fija mediante dhcpcd..."
    sed -i "/interface $INTERFACE/,+4d" /etc/dhcpcd.conf
    cat <<EOF >> /etc/dhcpcd.conf

interface $INTERFACE
static ip_address=$SERVER_IP/$NETMASK_SHORT
static routers=$GATEWAY
static domain_name_servers=$DNS_PROVISIONAL
EOF
    systemctl restart dhcpcd
else
    echo "[!] Gestor no detectado. Aplicando IP provisional por comando ip..."
    ip addr add "$SERVER_IP/$NETMASK_SHORT" dev "$INTERFACE" || true
fi

# =======================================================================
# 5. ASISTENTE INTERACTIVO DE ALMACENAMIENTO (SIN FORMATEAR)
# =======================================================================
echo ""
echo "[?] Discos de almacenamiento disponibles en el sistema:"
echo "--------------------------------------------------------------------------"
lsblk -n -o NAME,SIZE,FSTYPE,MODEL,MOUNTPOINT
echo "--------------------------------------------------------------------------"
read -p "[>] Escribe el nombre exacto del disco/partición YA FORMATEADO (ej. sdb o sdb1): " DISK_NAME

TARGET_DEV="/dev/$DISK_NAME"

if [ ! -b "$TARGET_DEV" ]; then
    echo "[!] El dispositivo $TARGET_DEV no existe. Abortando instalación."
    exit 1
fi

# Verificar si está montado en algún lado para desmontarlo de forma segura antes de reasignarlo
CURRENT_MOUNT=$(lsblk -no MOUNTPOINT "$TARGET_DEV" | head -n 1)
if [ -n "$CURRENT_MOUNT" ]; then
    echo "[-] Desmontando unidad activa en $CURRENT_MOUNT..."
    umount -l "$TARGET_DEV" || true
fi

# Auto-detectar el sistema de archivos actual y su UUID (Sin alterar la información existente)
FS_TYPE=$(blkid -o value -s TYPE "$TARGET_DEV" || lsblk -no FSTYPE "$TARGET_DEV")
DISK_UUID=$(blkid -o value -s UUID "$TARGET_DEV" || lsblk -no UUID "$TARGET_DEV")

if [ -z "$FS_TYPE" ] || [ -z "$DISK_UUID" ]; then
    echo "[!] Error: No se pudo identificar un sistema de archivos o UUID válido en $TARGET_DEV."
    echo "[!] Asegúrate de que la unidad tenga formato antes de lanzar el script."
    exit 1
fi

echo "[+] Formato detectado: $FS_TYPE"
echo "[+] UUID detectado: $DISK_UUID"

echo "[-] Configurando montaje persistente mediante UUID..."
mkdir -p "$MOUNT_POINT"

# Evitar duplicados eliminando registros antiguos del archivo fstab relacionados con este punto o UUID
sed -i "\|UUID=$DISK_UUID|d" /etc/fstab
sed -i "\|$MOUNT_POINT|d" /etc/fstab

# Escribir la instrucción de montaje automático adaptando el sistema de archivos dinámicamente
echo "UUID=$DISK_UUID $MOUNT_POINT $FS_TYPE defaults,noatime,nofail 0 2" >> /etc/fstab

echo "[-] Montando la unidad de almacenamiento..."
mount -a

# Comprobación de seguridad final del montaje
if ! mountpoint -q "$MOUNT_POINT"; then
    echo "[-] Intento secundario forzando montaje de $TARGET_DEV..."
    mount "$TARGET_DEV" "$MOUNT_POINT" || true
    if ! mountpoint -q "$MOUNT_POINT"; then
        echo "[!] Error crítico: No se pudo montar el disco en $MOUNT_POINT."
        exit 1
    fi
fi

# Definir las rutas físicas definitivas dentro del nuevo disco duro
LANCACHE_DATA="$MOUNT_POINT/data"
LANCACHE_LOGS="$MOUNT_POINT/logs"

echo "[-] Creando directorios internos de almacenamiento..."
mkdir -p "$PIHOLE_DATA" "$PIHOLE_DNSMASQ" "$LANCACHE_DATA" "$LANCACHE_LOGS"

# Otorgar permisos globales para mitigar conflictos de lectura/escritura de Docker
chmod -R 777 "$DIR_BASE"
chmod -R 777 "$MOUNT_POINT"

echo "[+] Almacenamiento listo y montado con éxito en: $MOUNT_POINT"

# =======================================================================
# 6. CREACIÓN DEL ESCENARIO DOCKER COMPOSE INTEGRADO
# =======================================================================
echo "[-] Generando el manifiesto actual docker-compose.yml..."
mkdir -p "$DIR_BASE"
cd "$DIR_BASE"

cat << EOF > docker-compose.yml
version: '3.8'

services:
  # --- LANCACHE DNS (Puerto 53 de la Máquina) ---
  lancache-dns:
    container_name: lancache-dns
    image: lancachenet/lancache-dns:latest
    restart: always
    ports:
      - "${SERVER_IP}:53:53/udp"
      - "${SERVER_IP}:53:53/tcp"
    environment:
      - LANCACHE_IP=${SERVER_IP}
      - UPSTREAM_DNS=1.1.1.1

  # --- LANCACHE MONOLITHIC (Puertos Web HTTP/HTTPS) ---
  lancache-monolithic:
    container_name: lancache-monolithic
    image: lancachenet/monolithic:latest
    restart: always
    ports:
      - "${SERVER_IP}:80:80/tcp"
      - "${SERVER_IP}:443:443/tcp"
    environment:
      - CACHE_DISK_SIZE=1000g
      - TZ=${ZONA_HORARIA}
    volumes:
      - ${LANCACHE_DATA}:/data/cache
      - ${LANCACHE_LOGS}:/data/logs

  # --- PI-HOLE (Panel Web accesible en el puerto alternativo 8080) ---
  pihole:
    container_name: pihole
    image: pihole/pihole:latest
    restart: always
    ports:
      - "${SERVER_IP}:8080:80/tcp"
    environment:
      TZ: '${ZONA_HORARIA}'
      WEBPASSWORD: '${PASSWORD_PIHOLE}'
      PIHOLE_DNS_: '1.1.1.1;8.8.8.8'
    volumes:
      - '${PIHOLE_DATA}:/etc/pihole'
      - '${PIHOLE_DNSMASQ}:/etc/dnsmasq.d'
EOF

# =======================================================================
# 7. DESPLIEGUE Y DIRECCIONAMIENTO LOCAL
# =======================================================================
echo ""
echo "[-] Descargando imágenes y levantando los servicios..."
echo "--------------------------------------------------------------------------"
docker-compose up -d

echo ""
echo "[-] Aplicando configuración DNS final en el Host local..."
if [ -n "$INTERFACE" ]; then
    if systemctl is-active --quiet NetworkManager; then
        nmcli connection modify "$NM_CONN" ipv4.dns "$SERVER_IP"
        nmcli connection up "$NM_CONN"
    elif systemctl is-active --quiet systemd-networkd; then
        sed -i "s/DNS=.*/DNS=$SERVER_IP/" /etc/systemd/network/10-static-${INTERFACE}.network
        systemctl restart systemd-networkd
    elif systemctl is-active --quiet dhcpcd; then
        sed -i "s/static domain_name_servers=.*/static domain_name_servers=$SERVER_IP/" /etc/dhcpcd.conf
        systemctl restart dhcpcd
    else
        echo "nameserver $SERVER_IP" > /etc/resolv.conf
    fi
fi

echo "========================================================================="
echo " ¡INSTALACIÓN ESTRUCTURADA COMPLETADA EXITOSAMENTE!"
echo "========================================================================="
echo " -> IP Servidor Estática: $SERVER_IP"
echo " -> Caché de LanCache asignada al disco: /dev/$DISK_NAME"
echo " -> Servidor LanCache DNS Activo (Puerto 53)"
echo " -> Pi-hole Panel Web: http://$SERVER_IP:8080/admin"
echo " -> Contraseña Panel Pi-hole: $PASSWORD_PIHOLE"
echo "========================================================================="
