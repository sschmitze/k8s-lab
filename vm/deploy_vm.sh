#!/usr/bin/env bash
#
# deploy_vm.sh — reproducibly (re)create the k8s-cp lab VM on libvirt/KVM.
#
# Reads cloud-init files (user-data, meta-data, network-config) from its OWN
# directory, so keep this script next to them in ~/k8s-lab/vm/.
#
# NOTE: re-running this DESTROYS the existing VM and its overlay disk, then
# rebuilds from the base image. The base image itself is never deleted.
#
# Run as your normal user (the one in the 'libvirt' group); it uses sudo
# internally only for the privileged steps under /var/lib/libvirt/images.
#
set -euo pipefail

# ---- config -------------------------------------------------------------
VM_NAME="k8s-cp"
VCPUS=2
MEMORY=2048                       # MiB
DISK_SIZE="30G"
OS_VARIANT="ubuntu24.04"          # if "Unknown OS" error: osinfo-query os | grep ubuntu

IMG_DIR="/var/lib/libvirt/images"
BASE_IMG="${IMG_DIR}/noble-server-cloudimg-amd64.img"
OVERLAY="${IMG_DIR}/${VM_NAME}.qcow2"
BASE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
SUMS_URL="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"

# cloud-init files live next to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- sanity: cloud-init files must exist --------------------------------
for f in user-data meta-data network-config; do
  [[ -f "${SCRIPT_DIR}/${f}" ]] || { echo "ERROR: missing ${SCRIPT_DIR}/${f}"; exit 1; }
done

# ---- 1. fetch + verify base image (only if absent) ----------------------
if [[ ! -f "$BASE_IMG" ]]; then
  echo ">> Downloading Noble cloud image..."
  sudo wget -4 -O "$BASE_IMG" "$BASE_URL"
  sudo wget -4 -O "${IMG_DIR}/SHA256SUMS" "$SUMS_URL"
  ( cd "$IMG_DIR" && grep 'noble-server-cloudimg-amd64.img$' SHA256SUMS | sha256sum -c - )
else
  echo ">> Base image present, skipping download."
fi

# ---- 2. tear down any existing VM + its overlay -------------------------
if virsh dominfo "$VM_NAME" &>/dev/null; then
  echo ">> Removing existing VM '$VM_NAME'..."
  virsh destroy  "$VM_NAME" &>/dev/null || true
  virsh undefine "$VM_NAME" &>/dev/null || true
fi
sudo rm -f "$OVERLAY"

# ---- 3. create overlay disk backed by the base --------------------------
echo ">> Creating overlay disk (${DISK_SIZE})..."
sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$OVERLAY" "$DISK_SIZE"
sudo chown libvirt-qemu:kvm "$OVERLAY"   # let libvirt's qemu read/write it

# ---- 4. create the VM ---------------------------------------------------
echo ">> Creating VM '$VM_NAME'..."
virt-install --name "$VM_NAME" --memory "$MEMORY" --vcpus "$VCPUS" \
  --os-variant "$OS_VARIANT" \
  --disk path="$OVERLAY",format=qcow2,bus=virtio \
  --network network=default,model=virtio \
  --graphics none --noautoconsole --import \
  --cloud-init "user-data=${SCRIPT_DIR}/user-data,meta-data=${SCRIPT_DIR}/meta-data,network-config=${SCRIPT_DIR}/network-config"

# ---- 5. report ----------------------------------------------------------
echo ">> Waiting for boot / network..."
sleep 8
virsh domifaddr "$VM_NAME" || true
echo ">> Done. Try: ssh ubuntu@192.168.122.10"
