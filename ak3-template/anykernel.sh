### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
##
## Universal GKI flash template (installed by the build pipeline over the upstream
## WildKernels script before packaging). The pipeline injects the target-system
## gate below at build time (TARGET_SYS, controlled by the a17_compat switch):
##   - a12-16 (default, switch off): only Android 12/13/14/15/16 systems can flash
##   - a17    (switch on):           only Android 17 systems can flash
## Kernel rule (unchanged, GKI): the zip's kernel version must match the GKI kernel
## version the device is currently running (e.g. a 5.10.x zip on a 5.10 GKI device).

### AnyKernel setup
# global properties
properties() { '
kernel.string=GKI Kernel (KernelSU + SUSFS)
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
do.check_boot_version=0
device.name1=
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
keycheck.timeout=10
'; } # end properties


### AnyKernel install
## boot shell variables
block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto
no_magisk_check=1

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

# ---- target system gate (injected at build time: a12-16 or a17) ----
TARGET_SYS="@@TARGET_SYS@@"

sys_ver=$(getprop ro.build.version.release 2>/dev/null | tr -d '[:space:]')
sys_sdk=$(getprop ro.build.version.sdk 2>/dev/null | tr -d '[:space:]')
allowed=false
case "$TARGET_SYS" in
    a17)
        range_text="Android 17"
        case "$sys_ver" in 17|17.*) allowed=true ;; esac
        [ "$sys_sdk" = "37" ] && allowed=true
        ;;
    *)
        TARGET_SYS="a12-16"
        range_text="Android 12-16"
        case "$sys_ver" in 12|12.*|13|13.*|14|14.*|15|15.*|16|16.*) allowed=true ;; esac
        case "$sys_sdk" in 31|32|33|34|35|36) allowed=true ;; esac
        ;;
esac

if [ "$allowed" != true ]; then
    ui_print " " "  -> This package supports $range_text systems only."
    ui_print "  -> Detected system: ${sys_ver:-unknown} (SDK ${sys_sdk:-unknown})."
    abort "  -> System version mismatch, aborting."
fi
ui_print " " "  -> System check passed: ${sys_ver:-unknown} (target $range_text)."

# Environment hint only - never fatal: in a recovery/installer the kernel that runs
# here is the installer kernel, not necessarily the ROM's kernel. The list covers
# every GKI line this repo builds (5.10/5.15/6.1/6.6) plus the Android 17 GKI
# kernel (6.18, refs/heads/android17-6.18 on AOSP) and interim mainline-based
# kernels (6.16/6.17) so newer installer environments don't block.
kernel_version=$(cat /proc/version | awk -F '-' '{print $1}' | awk '{print $3}')
case $kernel_version in
    5.10*|5.15*|6.1*|6.6*|6.16*|6.17*|6.18*) ksu_supported=true ;;
    *) ksu_supported=false ;;
esac

if [ "$ksu_supported" != true ]; then
    ui_print " " "  -> WARNING: running kernel ($kernel_version) is not a known GKI version."
    ui_print "  -> Continuing anyway (version checks are disabled in this package)."
else
    ui_print " " "  -> GKI environment detected: $kernel_version"
fi

# boot install
split_boot

# Android 13+ GKI devices keep the generic ramdisk in init_boot, so their `boot` partition has
# none: flash the kernel only and leave init_boot / vendor_boot alone. Devices whose boot still
# carries a ramdisk take the normal unpack_ramdisk + write_boot path.
if [ -s "$SPLITIMG/ramdisk.cpio" ]; then
    unpack_ramdisk
    write_boot
else
    ui_print " " "  -> boot has no ramdisk (init_boot layout), kernel-only flash"
    flash_boot
fi

ui_print " "
ui_print "  -> Target systems: $range_text."
ui_print "     Kernel must match the device's GKI kernel version (e.g. 5.10.x)."
ui_print " "
