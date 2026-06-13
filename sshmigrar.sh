#!/bin/bash

# Evitar que se quede colgado si falla algo intermedio
set -e

# Validar parámetros de entrada
if [ "$#" -ne 4 ]; then
    echo "❌ Error: Parámetros incorrectos."
    echo "Uso: $0 <vm|lxc> <vmid_origen> <vmid_destino> <ip_destino>"
    echo "Ejemplo: $0 vm 103 803 192.168.31.8"
    exit 1
fi

TIPO=$(echo "$1" | tr '[:upper:]' '[:lower:]')
ID_ORIGEN=$2
ID_DESTINO=$3
IP_DESTINO=$4

# Verificar conexión SSH passwordless hacia el destino
if ! ssh -o PasswordAuthentication=no -o ConnectTimeout=3 root@"$IP_DESTINO" "echo" &>/dev/null; then
    echo "❌ Error: No hay conexión SSH sin contraseña hacia root@$IP_DESTINO"
    echo "Por favor, ejecuta primero: ssh-copy-id root@$IP_DESTINO"
    exit 1
fi

# --- MIGRACIÓN DE MÁQUINA VIRTUAL (VM) ---
if [ "$TIPO" == "vm" ]; then
    CONF_ORIGEN="/etc/pve/qemu-server/${ID_ORIGEN}.conf"
    
    if [ ! -f "$CONF_ORIGEN" ]; then
        echo "❌ Error: No existe la VM $ID_ORIGEN en este nodo."
        exit 1
    fi

    echo "⚙️  Detectando configuración de la VM $ID_ORIGEN..."
    # Buscar el disco principal en local-lvm (sata, scsi, virtio o ide)
    DISCO_LINEA=$(grep -E '^(sata|scsi|virtio|ide)[0-9]:' "$CONF_ORIGEN" | grep 'local-lvm' | head -n 1)
    
    if [ -z "$DISCO_LINEA" ]; then
        echo "❌ Error: No se encontró ningún disco en 'local-lvm' asignado a esta VM."
        exit 1
    fi

    # Extraer el volumen (ej: vm-103-disk-2) y el tamaño asignado (ej: 60G)
    VOL_ORIGEN=$(echo "$DISCO_LINEA" | sed -E 's/.*local-lvm:(vm-[0-9]+-disk-[0-9]+),.*/\1/')
    TAMANO=$(echo "$DISCO_LINEA" | sed -E 's/.*size=([0-9]+[G|M|T]).*/\1/')
    BUS_TIPO=$(echo "$DISCO_LINEA" | cut -d':' -f1)

    echo "📊 Disco origen detectado: /dev/pve/$VOL_ORIGEN ($TAMANO)"
    echo "🚀 Creando volumen vacío en el destino ($IP_DESTINO)..."
    ssh root@"$IP_DESTINO" "lvcreate -V ${TAMANO} -T pve/data -n vm-${ID_DESTINO}-disk-0"

    echo "🔒 Transfiriendo bloques con DD + GZIP a través de SSH..."
    dd if="/dev/pve/$VOL_ORIGEN" bs=4M status=progress | gzip -c | ssh root@"$IP_DESTINO" "gunzip -c | dd of=/dev/pve/vm-${ID_DESTINO}-disk-0 bs=4M"

    echo "📝 Copiando y adaptando archivo de configuración..."
    # Copiar archivo temporal para no romper el original
    TMP_CONF=$(mktemp)
    cp "$CONF_ORIGEN" "$TMP_CONF"

    # Modificar la línea del disco para el nuevo destino y limpiar el parámetro maldito de Spice si existe
    sed -i -E "s/local-lvm:vm-[0-9]+-disk-[0-9]+/local-lvm:vm-${ID_DESTINO}-disk-0/g" "$TMP_CONF"
    sed -i -E "s/size=[0-9]+[G|M|T]/size=${TAMANO}/g" "$TMP_CONF"
    sed -i '/spice_enhancements/d' "$TMP_CONF" # Borra la línea de spice_enhancements por si acaso

    # Enviar la configuración al directorio del Proxmox destino
    scp "$TMP_CONF" root@"$IP_DESTINO"Matching:"/etc/pve/qemu-server/${ID_DESTINO}.conf"
    rm -f "$TMP_CONF"

    echo "✅ VM ${ID_ORIGEN} migrada con éxito a la VM ${ID_DESTINO} en $IP_DESTINO"

# --- MIGRACIÓN DE CONTENEDOR (LXC) ---
elif [ "$TIPO" == "lxc" ]; then
    CONF_ORIGEN="/etc/pve/lxc/${ID_ORIGEN}.conf"

    if [ ! -f "$CONF_ORIGEN" ]; then
        echo "❌ Error: No existe el contenedor LXC $ID_ORIGEN en este nodo."
        exit 1
    fi

    echo "⚙️  Detectando configuración del LXC $ID_ORIGEN..."
    TAMANO=$(grep 'rootfs:' "$CONF_ORIGEN" | sed -E 's/.*size=([0-9]+[G|M|T]).*/\1/')
    
    if [ -z "$TAMANO" ]; then TAMANO="40G"; fi # Tamaño por defecto por si acaso

    echo "🚀 Creando subvolumen de destino en local-lvm ($IP_DESTINO)..."
    ssh root@"$IP_DESTINO" "lvcreate -V ${TAMANO} -T pve/data -n vm-${ID_DESTINO}-disk-0"
    
    echo "💻 Formateando volumen destino en ext4..."
    ssh root@"$IP_DESTINO" "mkfs.ext4 /dev/pve/vm-${ID_DESTINO}-disk-0"

    echo "📦 Montando estructuras temporales y transfiriendo datos via RSYNC..."
    # Crear puntos de montaje temporales locales y remotos para volcar los archivos limpios
    mkdir -p /mnt/kvm_migrar_origen
    mount /dev/pve/vm-${ID_ORIGEN}-disk-0 /mnt/kvm_migrar_origen

    ssh root@"$IP_DESTINO" "mkdir -p /mnt/kvm_migrar_destino && mount /dev/pve/vm-${ID_DESTINO}-disk-0 /mnt/kvm_migrar_destino"

    # Transferencia a nivel de ficheros reales (no copia bloques vacíos)
    rsync -azPX --numeric-ids /mnt/kvm_migrar_origen/ root@"$IP_DESTINO":/mnt/kvm_migrar_destino/

    # Desmontar todo al terminar
    echo "🧹 Desmontando y limpiando directorios temporales..."
    umount /mnt/kvm_migrar_origen
    rmdir /mnt/kvm_migrar_origen
    ssh root@"$IP_DESTINO" "umount /mnt/kvm_migrar_destino && rmdir /mnt/kvm_migrar_destino"

    echo "📝 Copiando y adaptando archivo de configuración del LXC..."
    TMP_CONF=$(mktemp)
    cp "$CONF_ORIGEN" "$TMP_CONF"
    sed -i -E "s/local-lvm:vm-[0-9]+-disk-[0-9]+/local-lvm:vm-${ID_DESTINO}-disk-0/g" "$TMP_CONF"
    
    scp "$TMP_CONF" root@"$IP_DESTINO"Matching:"/etc/pve/lxc/${ID_DESTINO}.conf"
    rm -f "$TMP_CONF"

    echo "✅ LXC ${ID_ORIGEN} migrado con éxito al LXC ${ID_DESTINO} en $IP_DESTINO"

else
    echo "❌ Tipo no válido. Utiliza 'vm' o 'lxc'."
    exit 1
fi
