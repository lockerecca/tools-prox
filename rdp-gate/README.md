# rdp-gate

Apertura **bajo demanda** del puerto RDP (3389) en el borde `192.168.31.3`.
En lugar de tener el 3389 abierto a todo Internet, el firewall solo deja pasar
las IPs que estén en el set nft `rdp_allow`, y ese set se rellena al visitar una
web protegida con Google OAuth. Cada apertura caduca sola a la **1 hora**.

## Flujo

```
Usuario -> https://rdp.forseti.es  (Apache + OIDC Google)
            |  autenticado, abre open.php
            v
        open.php  -- envia REMOTE_ADDR (IPv4) por socket Unix -->  rdp-gated.py (root)
                                                                      |
                                                          nft add element rdp_allow { IP timeout 1h }
                                                                      v
                              firewall .3: el DNAT 3389 -> .111 solo pasa si la IP esta en rdp_allow
```

## Componentes

| Archivo | Destino en el .3 | Función |
|---|---|---|
| `open.php` | `/var/www/rdp/open.php` | Página tras login OIDC. Lee `REMOTE_ADDR`, lo manda al daemon. No acepta parámetros del usuario. |
| `rdp-gated.py` | `/usr/local/sbin/rdp-gated.py` | Daemon root. Valida IPv4 e inserta en el set nft con timeout. Socket `root:www-data 0660`. |
| `rdp-gate.service` | `/etc/systemd/system/` | Unit systemd del daemon. |
| `rdp.forseti.es.conf` | `/etc/apache2/sites-available/` | VHost Apache con OIDC. Sirve PHP local, NO proxia. |

## Seguridad

- La IP la fija el servidor (`REMOTE_ADDR`), nunca el cliente. No se confía en `X-Forwarded-For`.
- Solo IPv4 directa: si llega por IPv6 o tras proxy, se rechaza (el RDP no se abre).
- `nft` se invoca con argv (lista), nunca por shell -> sin inyección.
- El socket Unix es `root:www-data 0660` -> solo Apache puede hablarle.
- Doble validación IPv4: en PHP y en el daemon.

## CAMBIO REQUERIDO en /etc/nftables.conf del .3

El daemon rellena el set `rdp_allow`, pero el set y la regla que lo usa hay que
crearlos. Sin esto, el daemon mete IPs en un set que no existe (falla) y el 3389
sigue abierto a todo. Aplicar en la tabla `inet filter`:

```nft
# 1) Declarar el set DENTRO de la tabla inet filter (junto a las chains)
    set rdp_allow {
        type ipv4_addr
        flags timeout
    }
```

Y **sustituir** la regla actual del RDP en la chain `forward`:

```nft
# ANTES (abierto a todo):
#   ip daddr 192.168.31.111 tcp dport 3389 accept

# DESPUES (solo IPs autorizadas por la web):
    ip daddr 192.168.31.111 tcp dport 3389 ip saddr @rdp_allow accept
```

> Nota: el set vive en `inet filter` (FAMILY=inet, TABLE=filter en `rdp-gated.py`),
> que coincide con la cabecera de la tabla del chain forward. Verificar que esos
> dos valores en el daemon casan con la tabla real antes de arrancar.

## Instalación (en el .3)

```bash
# PHP
install -d -o www-data -g www-data /var/www/rdp
install -m 0644 open.php /var/www/rdp/open.php

# Daemon
install -m 0755 rdp-gated.py /usr/local/sbin/rdp-gated.py
install -m 0644 rdp-gate.service /etc/systemd/system/rdp-gate.service

# Apache vhost (requiere los includes ssl-forseti/oidc-base ya presentes)
install -m 0644 rdp.forseti.es.conf /etc/apache2/sites-available/rdp.forseti.es.conf
a2ensite rdp.forseti.es

# nftables: añadir el set rdp_allow y cambiar la regla del 3389 (ver arriba)
nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf

systemctl daemon-reload
systemctl enable --now rdp-gate.service
systemctl reload apache2
```

## Dependencias previas

- `rdp.forseti.es` con DNS (split-horizon AdGuard + público) y cert en `ssl-forseti.conf`.
- OIDC ya configurado (`oidc-base.conf`, `oidc-users.conf`) — mismo cliente Google que login/mcadmin.
- DNAT `3389 -> 192.168.31.111` ya presente en el nat (ya está).
