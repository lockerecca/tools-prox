#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# rdp-gated.py
# Daemon de apertura RDP: recibe UNA IP por socket Unix y la mete en el set
# nft `rdp_allow` con timeout. Corre como root (systemd) -> tiene CAP_NET_ADMIN.
#
# Seguridad:
#   - nft se invoca con argv (lista), NUNCA con /bin/sh  -> sin inyeccion de shell
#   - la IP se valida como IPv4 estricta antes de tocar nada (doble validacion:
#     tambien la valida la pagina PHP)
#   - el socket es root:www-data 0660 -> solo Apache (www-data) puede hablarle
#
# Ajusta FAMILY/TABLE a tu tabla real (cabecera `table <FAMILY> <TABLE> {` en
# /etc/nftables.conf, la que contiene tu chain forward).

import os
import grp
import socket
import ipaddress
import subprocess

SOCK    = "/run/rdp-gate.sock"
FAMILY  = "inet"        # <-- ajusta: inet | ip   (mira la cabecera de tu tabla)
TABLE   = "filter"      # <-- ajusta: nombre de la tabla del chain forward
SETNAME = "rdp_allow"
TIMEOUT = "1h"          # caducidad del acceso (auto-cierre)


def valid_ipv4(s: str):
    try:
        return ipaddress.IPv4Address(s.strip())
    except ValueError:
        return None


def nft(*args):
    # argv directo, sin shell -> sin inyeccion
    subprocess.run(["nft", *args], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def open_ip(ip: str):
    elem = ("{", ip, "timeout", TIMEOUT, "}")
    # delete+add: refresca el timeout si la IP ya estaba (delete falla sin ruido
    # si no existe, lo ignoramos)
    nft("delete", "element", FAMILY, TABLE, SETNAME, *elem)
    nft("add",    "element", FAMILY, TABLE, SETNAME, *elem)


def main():
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(SOCK)
    gid = grp.getgrnam("www-data").gr_gid
    os.chown(SOCK, 0, gid)     # root:www-data
    os.chmod(SOCK, 0o660)
    s.listen(8)

    while True:
        conn, _ = s.accept()
        try:
            data = conn.recv(64).decode("ascii", "ignore")
            ip = valid_ipv4(data)
            if ip is not None:
                open_ip(str(ip))
                conn.sendall(b"OK\n")
            else:
                conn.sendall(b"ERR\n")
        except Exception:
            try:
                conn.sendall(b"ERR\n")
            except Exception:
                pass
        finally:
            conn.close()


if __name__ == "__main__":
    main()
