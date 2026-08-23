# Arch Linux LanCache + Pi-hole + Dashboard AI Installer

Este repositorio contiene un script en Bash optimizado para desplegar una infraestructura completa de aceleración de descargas de videojuegos (**LanCache**), un servidor de filtrado de publicidad y telemetría (**Pi-hole**), y un panel de estadísticas en tiempo real (**LanCache-Dashboard**). 

El instalador está diseñado y blindado específicamente para funcionar de manera infalible en instalaciones limpias y minimalistas de **Arch Linux**.

## 🚀 Características del Ecosistema
* **IP Fija Estructural**: Configura el servidor de forma automática con la IP fija `192.168.0.7` sin romper sesiones SSH durante el despliegue.
* **DNS en Cascada (Chaining)**: Pi-hole atiende el puerto `53` bloqueando anuncios y telemetría, y reenvía de forma inteligente las peticiones de videojuegos a LanCache-DNS (puerto interno `5353`).
* **Protección del Kernel**: Detecta actualizaciones en caliente del kernel de Arch para evitar el colapso de los módulos de red de Docker.
* **Panel Unificado**: Visualiza el rendimiento de la caché en el puerto `8080` y administra Pi-hole en el puerto `8081`.

---

## 🛠️ Requisitos Mínimos
* Una instalación limpia de **Arch Linux** con acceso a internet.
* Privilegios de `root` o un usuario configurado en el archivo `sudoers`.
* Al menos **25 GB de espacio libre** en el punto de montaje seleccionado (el script reserva un margen de seguridad de 15 GB).

---

## 💻 Instalación

Puedes ejecutar el instalador directamente desde tu servidor Arch Linux ejecutando los siguientes comandos:


git clone https://github.com/Rupeji/InstaladorArch/
cd InstaladorArch
chmod +x instalador.sh
sudo ./instalador.sh

### Pasos durante la ejecución:
1. El script actualizará los espejos de Pacman e instalará Docker de forma nativa.
2. Te mostrará los discos montados y te pedirá la **ruta absoluta** del almacenamiento (ej. `/` o `/mnt/disco2`).
3. Creará los contenedores y reconfigurará la red interna.
4. **Al finalizar, ejecuta obligatoriamente:** `sudo reboot`

---

## 📊 Direcciones de Administración

Una vez reiniciado el servidor, podrás acceder a los paneles desde cualquier navegador de tu red local:

* **Panel de Estadísticas LanCache**: `http://192.168.0.7:8080`
* **Panel de Control Pi-hole**: `http://192.168.0.7:8081/admin` *(Contraseña por defecto: `admin`)*
* **Acceso SSH al Servidor**: `ssh tu_usuario@192.168.0.7`

---

## 🖥️ Configuración en Clientes (Windows 11)

Para que tus ordenadores de juegos y consolas utilicen la caché y el bloqueador de publicidad, debes configurar su DNS para que apunte a la IP del servidor (`192.168.0.7`). Sigue estos pasos en **Windows 11**:

1. Abre la **Configuración** de Windows 11 (`Win + I`).
2. Ve a la sección **Red e internet** en el menú lateral izquierdo.
3. Haz clic en tu tipo de conexión activa: **Wi-Fi** o **Ethernet**.
4. Busca la opción **Asignación de DNS** y haz clic en el botón **Editar**.
5. Cambia el menú desplegable de *Automático (DHCP)* a **Manual**.
6. Activa el interruptor de **IPv4**.
7. Configura los siguientes campos:
   * **DNS preferido**: `192.168.0.7`
   * **Cifrado de DNS preferido**: *Dejar en "Solo no cifrado" (Unencrypted only)*
   * **DNS alternativo**: *Dejar en blanco (Para asegurar que todo el tráfico pase por el servidor)*
8. Haz clic en **Guardar**.

> 💡 **Verificación**: Abre una terminal de Windows (`cmd` o `PowerShell`) y ejecuta `nslookup steampowered.com`. Si la respuesta indica que el servidor que resuelve es `192.168.0.7`, la configuración se ha completado con éxito. ¡Tus descargas de Steam, Epic Games, Riot, Xbox, etc., ahora volarán y navegarás sin anuncios!
