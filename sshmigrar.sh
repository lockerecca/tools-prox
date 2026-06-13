#!/bin/bash

# Evitar que el script continúe si un comando intermedio falla
set -e

# 1. Validar parámetros de entrada
if [ "$#" -ne 4 ]; then
    echo "❌ Error: Parámetros incorrectos."
    echo "Uso: curl -sSL URL | bash -s -- <vm|lxc> <vmid_origen> <vmid_destino> <ip_destino>"
    exit 1
fi

TIPO=$(echo "$1" | tr '[:upper:]' '[:lower:]')
ID_ORIGEN=$2
ID_DESTINO=$3
IP_DESTINO=$4

# 2. Asegurar que sshpass está disponible para gestionar la contraseña en el flujo
if ! command -v sshpass &>/dev/null; then
    echo "📦 Instalando dependencia temporal (sshpass)..."
    apt-get update -y && apt-get install -y sshpass
fi

# 3. Solicitar la contraseña de root destino de forma segura
echo -n "🔑 Introduce la contraseña de root de $IP_DESTINO: "
read -s SSH_PASS
echo ""

# Configurar alias seguro para los comandos SSH usando la contraseña en memoria
SSH_CMD="sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$IP_DESTINO"
SCP_CMD="sshpass -p $SSH_PASS scp -o StrictHostKeyChecking=no"

# --- MIGRACIÓN DE MÁQUINA VIRTUAL (VM) ---
if [ "$TIPO" == "vm" ]; then
    CONF_ORIGEN="/etc/pve/qemu-server/${ID_ORIGEN}.conf"
    
    if [ ! -f "$CONF_ORIGEN" ]; then
        echo "❌ Error: No existe la VM $ID_ORIGEN en este nodo."
        exit 1
    fi

    echo "⚙️  Analizando configuración de la VM $ID_ORIGEN..."
    DISCO_LINEA=$(grep -E '^(sata|scsi|virtio|ide)[0-9]:' "$CONF_ORIGEN" | grep 'local-lvm' | head -n 1)
    
    if [ -z "$DISCO_LINEA" ]; then
        echo "❌ Error: No se encontró disco en local-lvm para esta VM."
        exit 1
    fi

    VOL_ORIGEN=$(echo "$DISCO_LINEA" | sed -E 's/.*local-lvm:(vm-[0-9]+-disk-[0-9]+),.*/\1/')
    TAMANO=$(echo "$DISCO_LINEA" | sed -E 's/.*size=([0-9]+[G|M|T]).*/\1/')

    echo "🚀 Creando volumen de destino de $TAMANO en $IP_DESTINO..."
    $SSH_CMD "lvcreate -V ${TAMANO} -T pve/data -n vm-${ID_DESTINO}-disk-0"

    echo "🔒 Transfiriendo bloques con DD + GZIP..."
    # Pasamos la contraseña al SSH intermedio dentro del pipe
    dd if="/dev/pve/$VOL_ORIGEN" bs=4M status=progress | gzip -c | sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no root@"$IP_DESTINO" "gunzip -c | dd of=/dev/pve/vm-${ID_DESTINO}-disk-0 bs=4M"

    echo "📝 Adaptando archivo de configuración en el destino..."
    TMP_CONF=$(mktemp)
    cp "$CONF_ORIGEN" "$TMP_CONF"
    
    sed -i -E "s/local-lvm:vm-[0-9]+-disk-[0-9]+/local-lvm:vm-${ID_DESTINO}-disk-0/g" "$TMP_CONF"
    sed -i -E "s/size=[0-9]+[G|M|T]/size=${TAMANO}/g" "$TMP_CONF"
    sed -i '/spice_enhancements/d' "$TMP_CONF" # Eliminación automática del bloqueo de vídeo

    $SCP_CMD "$TMP_CONF" root@"$IP_DESTINO":"/etc/pve/qemu-server/${ID_DESTINO}.conf"
    rm -f "$TMP_CONF"

    echo "✅ VM ${ID_ORIGEN} migrada correctamente a la VM ${ID_DESTINO} en $IP_DESTINO"

# --- MIGRACIÓN DE CONTENEDOR (LXC) ---
elif [ "$TIPO" == "lxc" ]; then
    CONF_ORIGEN="/etc/pve/lxc/${ID_ORIGEN}.conf"

    if [ ! -f "$CONF_ORIGEN" ]; then
        echo "❌ Error: No existe el LXC $ID_ORIGEN."
        exit 1
    fi

    TAMANO=$(grep 'rootfs:' "$CONF_ORIGEN" | sed -E 's/.*size=([0-9]+[G|M|T]).*/\1/')
    if [ -z "$TAMANO" ]; then TAMANO="40G"; fi

    echo "🚀 Creando y formateando subvolumen en el destino..."
    $SSH_CMD "lvcreate -V ${TAMANO} -T pve/data -n vm-${ID_DESTINO}-disk-0 && mkfs.ext4 /dev/pve/vm-${ID_DESTINO}-disk-0"

    echo "📦 Montando estructuras y sincronizando ficheros reales..."
    mkdir -p /mnt/kvm_migrar_origen
    mount /dev/pve/vm-${ID_ORIGEN}-disk-0 /mnt/kvm_migrar_origen
    $SSH_CMD "mkdir -p /mnt/kvm_migrar_destino && mount /dev/pve/vm-${ID_DESTINO}-disk-0 /mnt/kvm_migrar_destino"

    # Sincronización remota usando sshpass inyectado en rsync
    rsync -azPX --numeric-ids -e "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no" /mnt/kvm_migrar_origen/ root@"$IP_DESTINO":/mnt/kvm_migrar_destino/

    echo "🧹 Desmontando y limpiando directorios temporales..."
    umount /mnt/kvm_migrar_origen && rmdir /mnt/kvm_migrar_origen
    $SSH_CMD "umount /mnt/kvm_migrar_destino && rmdir /mnt/kvm_migrar_destino"

    echo "📝 Transfiriendo configuración del LXC..."
    TMP_CONF=$(mktemp)
    cp "$CONF_ORIGEN" "$TMP_CONF"
    sed -i -E "s/local-lvm:vm-[0-9]+-disk-[0-9]+/local-lvm:vm-${ID_DESTINO}-disk-0/g" "$TMP_CONF"
    
    $SCP_CMD "$TMP_CONF" root@"$IP_DESTINO":"/etc/pve/lxc/${ID_DESTINO}.conf"
    rm -f "$TMP_CONF"

    echo "✅ LXC ${ID_ORIGEN} migrado correctamente al LXC ${ID_DESTINO} en $IP_DESTINO"
fi

# Limpieza de variables de entorno críticas por seguridad
unset SSH_PASS
echo "🍀 Proceso finalizado. Que pases buena noche."
