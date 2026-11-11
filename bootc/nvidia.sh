#!/bin/sh
# Builds NVIDIA's driver (from RPM Fusion) into the image, for the image's
# own kernel. Run by bootc/Containerfile when NVIDIA=true.
#
# Secure Boot: kernel modules must be signed by a key the machine trusts.
# Pass a fixed key as the build secrets akmods_key (private key) and
# akmods_cert (DER certificate); enroll the certificate once with
#   sudo mokutil --import /etc/pki/akmods/certs/public_key.der
# Without them, the modules are signed with a throwaway key, which only works
# with Secure Boot off. The private key is never left in the image.
set -eux

kver="$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | tail -1)"
dnf -y install "kernel-devel-$kver" akmod-nvidia xorg-x11-drv-nvidia-cuda

if [ -s /run/secrets/akmods_key ] && [ -s /run/secrets/akmods_cert ]; then
  install -d -m 0755 /etc/pki/akmods/certs /etc/pki/akmods/private
  install -m 0600 /run/secrets/akmods_key /etc/pki/akmods/private/private_key.priv
  install -m 0644 /run/secrets/akmods_cert /etc/pki/akmods/certs/public_key.der
  echo "Signing the NVIDIA modules with the provided key"
else
  echo "No signing key given: the NVIDIA modules need Secure Boot off"
fi

akmods --force --kernels "$kver"
ls "/usr/lib/modules/$kver/extra/nvidia/"nvidia.ko*   # fails if the build failed

# Sway refuses NVIDIA's driver unless started with --unsupported-gpu.
sed -i -E 's/^Exec=(\S*sway)$/Exec=\1 --unsupported-gpu/' /usr/share/wayland-sessions/sway.desktop
grep -q -- '--unsupported-gpu' /usr/share/wayland-sessions/sway.desktop

# Never ship a private signing key; the image is public.
rm -rf /etc/pki/akmods/private/*
dnf -y remove "kernel-devel-$kver"
