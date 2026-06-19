#!/bin/bash

# Migración de VM/LXC entre nodos Proxmox sin cluster, vía SSH.
# Copia TODOS los discos del invitado, comprime con zstd multi-hilo y
# transfiere la configuración renombrando solo el VMID (conserva índices
# y tamaños de cada disco).
#
# Uso:  ./sshmigrar.sh <vm|lxc> <vmid_origen> <vmid_destino> <ip_destino>
# Tip:  si lo lanzas con  curl -sSL URL | bash -s -- ...  la contraseña se
#       lee de /dev/tty, así que funciona igualmente.

set -e

# 1. Validar parámetros de entrada
if [ "$#" -ne 4 ]; then
    echo "❌ Error: Parámetros incorrectos."
    echo "Uso: ./sshmigrar.sh <vm|lxc> <vmid_origen> <vmid_destino> <ip_destino>"
    exit 1
fi

TIPO=$(echo "$1" | tr '[:upper:]' '[:lower:]')
ID_ORIGEN=$2
ID_DESTINO=$3
IP_DESTINO=$4

# 2. Dependencias temporales (sshpass para la contraseña, zstd para comprimir)
if ! command -v sshpass &>/dev/null; then
    echo "📦 Instalando dependencia temporal (sshpass)..."
    apt-get update -y && apt-get install -y sshpass
fi
if ! command -v zstd &>/dev/null; then
    echo "📦 Instalando dependencia temporal (zstd)..."
    apt-get update -y && apt-get install -y zstd
fi

# 3. Solicitar la contraseña de root destino de forma segura.
#    < /dev/tty permite que funcione también con  curl | bash.
echo -n "🔑 Introduce la contraseña de root de $IP_DESTINO: "
read -rs SSH_PASS < /dev/tty
echo ""

# sshpass -e lee la contraseña de la variable SSHPASS (no de la línea de
# comandos), evitando problemas con espacios o caracteres especiales.
export SSHPASS="$SSH_PASS"
SSH_CMD="sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$IP_DESTINO"
SCP_CMD="sshpass -e scp -o StrictHostKeyChecking=no"

# --- MIGRACIÓN DE MÁQUINA VIRTUAL (VM) ---
if [ "$TIPO" == "vm" ]; then
    CONF_ORIGEN="/etc/pve/qemu-server/${ID_ORIGEN}.conf"

    if [ ! -f "$CONF_ORIGEN" ]; then
        echo "❌ Error: No existe la VM $ID_ORIGEN en este nodo."
        exit 1
    fi

    # Aviso de seguridad: copiar un disco de una VM encendida = riesgo de corrupción
    if qm status "$ID_ORIGEN" 2>/dev/null | grep -q running; then
        echo "⚠️  La VM $ID_ORIGEN está ENCENDIDA. Copiar su disco en caliente puede corromper los datos."
        echo -n "   Escribe 'si' para continuar de todos modos (recomendado: apagarla antes): "
        read -r CONFIRMA < /dev/tty
        [ "$CONFIRMA" == "si" ] || { echo "Abortado."; exit 1; }
    fi

    echo "⚙️  Analizando configuración de la VM $ID_ORIGEN..."
    # Todas las líneas de disco en local-lvm, excluyendo discos 'unused' (sin size=)
    mapfile -t DISCO_LINEAS < <(grep -E 'local-lvm:vm-[0-9]+-disk-[0-9]+' "$CONF_ORIGEN" | grep -vE '^unused')

    if [ "${#DISCO_LINEAS[@]}" -eq 0 ]; then
        echo "❌ Error: No se encontró ningún disco en local-lvm para esta VM."
        exit 1
    fi

    echo "   Discos detectados: ${#DISCO_LINEAS[@]}"

    for LINEA in "${DISCO_LINEAS[@]}"; do
        VOL_ORIGEN=$(echo "$LINEA" | grep -oE 'vm-[0-9]+-disk-[0-9]+' | head -n1)
        DISK_NUM=$(echo "$VOL_ORIGEN" | grep -oE 'disk-[0-9]+' | grep -oE '[0-9]+')
        VOL_DESTINO="vm-${ID_DESTINO}-disk-${DISK_NUM}"
        TAMANO=$(echo "$LINEA" | grep -oE 'size=[0-9]+[KMGT]?' | head -n1 | cut -d= -f2)

        if [ -z "$TAMANO" ]; then
            echo "⚠️  Disco $VOL_ORIGEN sin tamaño detectable, lo salto."
            continue
        fi

        echo "🚀 [$VOL_ORIGEN → $VOL_DESTINO] Creando volumen de $TAMANO en $IP_DESTINO..."
        $SSH_CMD "lvcreate -V ${TAMANO} -T pve/data -n ${VOL_DESTINO}"

        echo "🔒 [$VOL_ORIGEN] Transfiriendo bloques con DD + ZSTD..."
        dd if="/dev/pve/${VOL_ORIGEN}" bs=4M status=progress | zstd -1 -T0 | \
            sshpass -e ssh -o StrictHostKeyChecking=no root@"$IP_DESTINO" \
            "zstd -d | dd of=/dev/pve/${VOL_DESTINO} bs=4M"
    done

    echo "📝 Adaptando archivo de configuración en el destino..."
    TMP_CONF=$(mktemp)
    cp "$CONF_ORIGEN" "$TMP_CONF"

    # Solo se cambia el VMID en los nombres de volumen; índice y tamaño intactos.
    sed -i -E "s/(local-lvm:)vm-${ID_ORIGEN}(-disk-[0-9]+)/\1vm-${ID_DESTINO}\2/g" "$TMP_CONF"
    sed -i '/spice_enhancements/d' "$TMP_CONF" # Quita bloque de vídeo que puede estorbar

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

    if pct status "$ID_ORIGEN" 2>/dev/null | grep -q running; then
        echo "⚠️  El LXC $ID_ORIGEN está ENCENDIDO. Sincronizar en caliente puede dar inconsistencias."
        echo -n "   Escribe 'si' para continuar de todos modos (recomendado: apagarlo antes): "
        read -r CONFIRMA < /dev/tty
        [ "$CONFIRMA" == "si" ] || { echo "Abortado."; exit 1; }
    fi

    echo "⚙️  Analizando puntos de montaje del LXC $ID_ORIGEN..."
    # rootfs + mpX en local-lvm, excluyendo 'unused'
    mapfile -t MP_LINEAS < <(grep -E 'local-lvm:vm-[0-9]+-disk-[0-9]+' "$CONF_ORIGEN" | grep -vE '^unused')

    if [ "${#MP_LINEAS[@]}" -eq 0 ]; then
        echo "❌ Error: No se encontró ningún volumen en local-lvm para este LXC."
        exit 1
    fi

    echo "   Volúmenes detectados: ${#MP_LINEAS[@]}"

    for LINEA in "${MP_LINEAS[@]}"; do
        VOL_ORIGEN=$(echo "$LINEA" | grep -oE 'vm-[0-9]+-disk-[0-9]+' | head -n1)
        DISK_NUM=$(echo "$VOL_ORIGEN" | grep -oE 'disk-[0-9]+' | grep -oE '[0-9]+')
        VOL_DESTINO="vm-${ID_DESTINO}-disk-${DISK_NUM}"
        TAMANO=$(echo "$LINEA" | grep -oE 'size=[0-9]+[KMGT]?' | head -n1 | cut -d= -f2)
        [ -z "$TAMANO" ] && TAMANO="40G"

        ORIG_MNT="/mnt/migrar_origen_${DISK_NUM}"
        DEST_MNT="/mnt/migrar_destino_${DISK_NUM}"

        echo "🚀 [$VOL_ORIGEN → $VOL_DESTINO] Creando y formateando volumen de $TAMANO..."
        $SSH_CMD "lvcreate -V ${TAMANO} -T pve/data -n ${VOL_DESTINO} && mkfs.ext4 -q /dev/pve/${VOL_DESTINO}"

        echo "📦 [$VOL_ORIGEN] Montando y sincronizando ficheros..."
        mkdir -p "$ORIG_MNT"
        mount "/dev/pve/${VOL_ORIGEN}" "$ORIG_MNT"
        $SSH_CMD "mkdir -p $DEST_MNT && mount /dev/pve/${VOL_DESTINO} $DEST_MNT"

        rsync -azPX --numeric-ids -e "sshpass -e ssh -o StrictHostKeyChecking=no" \
            "$ORIG_MNT/" root@"$IP_DESTINO":"$DEST_MNT/"

        echo "🧹 [$VOL_ORIGEN] Desmontando..."
        umount "$ORIG_MNT" && rmdir "$ORIG_MNT"
        $SSH_CMD "umount $DEST_MNT && rmdir $DEST_MNT"
    done

    echo "📝 Transfiriendo configuración del LXC..."
    TMP_CONF=$(mktemp)
    cp "$CONF_ORIGEN" "$TMP_CONF"
    sed -i -E "s/(local-lvm:)vm-${ID_ORIGEN}(-disk-[0-9]+)/\1vm-${ID_DESTINO}\2/g" "$TMP_CONF"

    $SCP_CMD "$TMP_CONF" root@"$IP_DESTINO":"/etc/pve/lxc/${ID_DESTINO}.conf"
    rm -f "$TMP_CONF"

    echo "✅ LXC ${ID_ORIGEN} migrado correctamente al LXC ${ID_DESTINO} en $IP_DESTINO"

else
    echo "❌ Error: Tipo '$TIPO' no válido. Usa 'vm' o 'lxc'."
    exit 1
fi

# Limpieza de variables de entorno críticas por seguridad
unset SSH_PASS SSHPASS
echo "🍀 Proceso finalizado. Que pases buena noche."
