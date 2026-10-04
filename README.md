# LTM SSH Free — Auto-Installer

Script de instalación y panel de gestión para [LTM SSH Free](https://ltmssh.darkzfull.cloud).

## Instalación en una VPS nueva (Ubuntu 20.04+)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DarkFull0726/ltmssh-installer/main/install.sh)
```

O manualmente:

```bash
wget https://raw.githubusercontent.com/DarkFull0726/ltmssh-installer/main/install.sh
bash install.sh
```

## Funciones del panel

| Opción | Descripción |
|--------|-------------|
| 1 | Instalación completa (Node.js, nginx, SSL, systemd) |
| 2 | Gestionar VPS (agregar / eliminar servidores) |
| 3 | Instalar protocolos SSH (BadVPN, HTTP Tunnel) |
| 4 | Estado del sistema y logs |
| 5 | Actualizar interfaz web |
| 6 | Desinstalar |

## Requisitos

- Ubuntu 20.04+ / Debian 11+
- Root access
- Puerto 443 abierto
