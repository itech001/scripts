#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Helper script that generates the signed kernel image

. "$(dirname "$0")/common.sh"

get_default_board

# Flags.
DEFINE_string arch "x86" \
  "The boot architecture: arm or x86. (Default: x86)"
# TODO(wad) once extlinux is dead, we can remove this.
DEFINE_boolean install ${FLAGS_FALSE} \
  "Controls whether extlinux is run on 'to'. (Default: false)"
DEFINE_string to "/tmp/boot" \
  "Path to populate with bootloader templates (Default: /tmp/boot)"
DEFINE_string usb_disk /dev/sdb3 \
  "Path syslinux should use to do a usb boot. Default: /dev/sdb3"
DEFINE_string boot_args "" \
  "Additional boot arguments to pass to the commandline (Default: '')"
DEFINE_boolean enable_rootfs_verification ${FLAGS_FALSE} \
  "Controls if verity is used for root filesystem checking (Default: false)"
DEFINE_integer verity_error_behavior 2 \
  "Verified boot error behavior [0: I/O errors, 1: reboot, 2: nothing] \
(Default: 2)"
DEFINE_integer verity_max_ios 1024 \
  "Optional number of outstanding I/O operations. (Default: 1024)"

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
set -e

# Common kernel command-line args
common_args="quiet console=tty2 init=/sbin/init boot=local rootwait ro noresume"
common_args="${common_args} noswap loglevel=1"

# Common verified boot command-line args
verity_common="dm_verity.error_behavior=${FLAGS_verity_error_behavior}"
verity_common="${verity_common} dm_verity.max_bios=${FLAGS_verity_max_ios}"

# Populate the x86 rootfs to support legacy and EFI bios config templates.
# The templates are used by the installer to populate partition 12 with
# the correct bootloader configuration.
# While we transition to that model, extlinux.conf will still be used
# on the root filesystem.
if [[ "${FLAGS_arch}" == "x86" ]]; then
  # Setup extlinux configuration.
  # TODO: For some reason the /dev/disk/by-uuid is not being generated by udev
  # in the initramfs. When we figure that out, switch to root=UUID=${UUID}.
  sudo mkdir -p ${FLAGS_to}
  # TODO(adlr): use initramfs for booting.
    cat <<EOF | sudo dd of="${FLAGS_to}"/extlinux.conf 2>/dev/null
DEFAULT chromeos-usb
PROMPT 0
TIMEOUT 0

label chromeos-usb
  menu label chromeos-usb
  kernel vmlinuz
  append ${common_args} root=/dev/sdb3 i915.modeset=1 cros_legacy

label chromeos-hd
  menu label chromeos-hd
  kernel vmlinuz
  append ${common_args} root=HDROOT i915.modeset=1 cros_legacy
EOF

  # Make partition bootable and label it.
  # TODO(wad) remove this after we've transitioned everyone to syslinux.
  if [[ ${FLAGS_install} -eq ${FLAGS_TRUE} ]]; then
    sudo extlinux -z --install "${FLAGS_to}"
  fi

  # /boot/syslinux must be installed in partition 12 as /syslinux/.
  SYSLINUX_DIR="${FLAGS_to}/syslinux"
  sudo mkdir -p "${SYSLINUX_DIR}"

  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/syslinux.cfg" 2>/dev/null
PROMPT 0
TIMEOUT 0

# the actual target
include /syslinux/default.cfg

# chromeos-usb.A
include /syslinux/usb.A.cfg

# chromeos-hd.A / chromeos-vhd.A
include /syslinux/root.A.cfg

# chromeos-hd.B / chromeos-vhd.B
include /syslinux/root.B.cfg
EOF
  info "Emitted ${SYSLINUX_DIR}/syslinux.cfg"

  if [[ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]]; then
    # To change the active target, only this file needs to change.
    cat <<EOF | sudo dd of="${SYSLINUX_DIR}/default.cfg" 2>/dev/null
DEFAULT chromeos-vusb.A
EOF
  else
      cat <<EOF | sudo dd of="${SYSLINUX_DIR}/default.cfg" 2>/dev/null
DEFAULT chromeos-usb.A
EOF
  fi
  info "Emitted ${SYSLINUX_DIR}/default.cfg"

  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/usb.A.cfg" 2>/dev/null
label chromeos-usb.A
  menu label chromeos-usb.A
  kernel vmlinuz.A
  append ${common_args} root=${FLAGS_usb_disk} i915.modeset=1 cros_legacy

label chromeos-vusb.A
  menu label chromeos-vusb.A
  kernel vmlinuz.A
  append ${common_args} ${verity_common} root=/dev/dm-0 i915.modeset=1 cros_legacy dm="DMTABLEA"
EOF
  info "Emitted ${SYSLINUX_DIR}/usb.A.cfg"

  # Different files are used so that the updater can only touch the file it
  # needs to for a given change.  This will minimize any potential accidental
  # updates issues, hopefully.
  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/root.A.cfg" 2>/dev/null
label chromeos-hd.A
  menu label chromeos-hd.A
  kernel vmlinuz.A
  append ${common_args} root=HDROOTA i915.modeset=1 cros_legacy

label chromeos-vhd.A
  menu label chromeos-vhd.A
  kernel vmlinuz.A
  append ${common_args} ${verity_common} root=/dev/dm-0 i915.modeset=1 cros_legacy dm="DMTABLEA"
EOF
  info "Emitted ${SYSLINUX_DIR}/root.A.cfg"

  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/root.B.cfg" 2>/dev/null
label chromeos-hd.B
  menu label chromeos-hd.B
  kernel vmlinuz.B
  append ${common_args} root=HDROOTB i915.modeset=1 cros_legacy

label chromeos-vhd.B
  menu label chromeos-vhd.B
  kernel vmlinuz.B
  append ${common_args} ${verity_common} root=/dev/dm-0 i915.modeset=1 cros_legacy dm="DMTABLEB"
EOF
  info "Emitted ${SYSLINUX_DIR}/root.B.cfg"

  cat <<EOF | sudo dd of="${SYSLINUX_DIR}/README" 2>/dev/null
Partition 12 contains the active bootloader configuration when
booting from a non-Chrome OS BIOS.  EFI BIOSes use /efi/*
and legacy BIOSes use this syslinux configuration.
EOF
  info "Emitted ${SYSLINUX_DIR}/README"

  # To cover all of our bases, now populate templated boot support for efi.
  sudo mkdir -p "${FLAGS_to}"/efi/boot
  sudo grub-mkimage -p /efi/boot -o "${FLAGS_to}/efi/boot/bootx64.efi" \
    part_gpt fat ext2 normal boot sh chain configfile linux
  # Templated variables:
  #  DMTABLEA, DMTABLEB -> '0 xxxx verity ... '
  # This should be replaced during postinst when updating the ESP.
  cat <<EOF | sudo dd of="${FLAGS_to}/efi/boot/grub.cfg" 2>/dev/null
set default=0
set timeout=2

# NOTE: These magic grub variables are a Chrome OS hack. They are not portable.

menuentry "local image A" {
  linux \$grubpartA/boot/vmlinuz ${common_args} i915.modeset=1 cros_efi root=/dev/\$linuxpartA
}

menuentry "local image B" {
  linux \$grubpartB/boot/vmlinuz ${common_args} i915.modeset=1 cros_efi root=/dev/\$linuxpartB
}

menuentry "verified image A" {
  linux \$grubpartA/boot/vmlinuz ${common_args} ${verity_common} i915.modeset=1 cros_efi root=/dev/dm-0 dm="DMTABLEA"
}

menuentry "verified image B" {
  linux \$grubpartB/boot/vmlinuz ${common_args} ${verity_common} i915.modeset=1 cros_efi root=/dev/dm-0 dm="DMTABLEB"
}

# FIXME: usb doesn't support verified boot for now
menuentry "Alternate USB Boot" {
  linux (hd0,3)/boot/vmlinuz ${common_args} root=/dev/sdb3 i915.modeset=1 cros_efi
}
EOF
  if [[ ${FLAGS_enable_rootfs_verification} -eq ${FLAGS_TRUE} ]]; then
    sudo sed -i -e 's/^set default=.*/set default=2/' \
       "${FLAGS_to}/efi/boot/grub.cfg"
  fi
  info "Emitted ${FLAGS_to}/efi/boot/grub.cfg"
  exit 0
fi

info "The target platform does not use bootloader templates."
