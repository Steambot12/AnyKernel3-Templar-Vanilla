### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## Enhanced by WiL for deep kernel cleanup

### AnyKernel setup
# Global properties
properties() { cat <<'PROP'
kernel.string=Templar Kernel by WiL (@Steambot12)
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=
device.name2=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
PROP
}

### Kernel identification
KERNEL_NAME="Templar"
KERNEL_AUTHOR="WiL"

### AnyKernel install
## Boot shell variables
block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto

# Import functions/variables and setup patching
. tools/ak3-core.sh

# Set home directory (AnyKernel working directory)
home=$(pwd)

## Deep cleanup - removes persistent kernel configs
deep_kernel_cleanup() {
    ui_print "→ Cleaning old kernel configs..."

    {
        # NOTE: Only clean persistent storage (/data paths)
        # DO NOT manipulate live system state (sysfs/procfs) in recovery mode
        # Live system cleanup happens in post-boot script instead

        # 1. Module cleanup (cached DLKM under /data only).
        # Do NOT touch /vendor_dlkm: this zip ships no modules (do.modules=0),
        # so the new kernel reuses the existing vendor modules in place.
        if [ -d /data/vendor/modules ]; then
            rm -rf /data/vendor/modules/*
        fi

        [ -d /data/system/modules ] && rm -rf /data/system/modules/*

        # 2. Sysctl & kernel parameters (persistent configs only)
        rm -rf /data/vendor/sysctl/* 2>/dev/null
        rm -f /data/local/kernel.sysctl 2>/dev/null
        rm -f /data/vendor/etc/sysctl.d/*.conf 2>/dev/null

        # 3. Scheduler configs (persistent storage only)
        rm -rf /data/vendor/scheduler/* 2>/dev/null
        rm -rf /data/vendor/cgroup/* 2>/dev/null

        # 4. I/O scheduler configs (persistent storage only)
        rm -rf /data/vendor/iosched/* 2>/dev/null

        # 5. CPUFreq & governor cleanup (persistent storage only)
        rm -rf /data/vendor/cpufreq/* 2>/dev/null
        rm -rf /data/system/cpufreq/* 2>/dev/null
        rm -rf /data/vendor/perf/* 2>/dev/null

        # 6. Thermal configs
        rm -rf /data/vendor/thermal/* 2>/dev/null
        rm -rf /data/vendor/thermal_config/* 2>/dev/null
        rm -f /data/.tp/* 2>/dev/null

        # 7. Kernel cache & state
        rm -rf /data/vendor/kernel/* 2>/dev/null
        rm -rf /data/kernel/* 2>/dev/null

        # 8. BPF/eBPF persistent data only
        [ -d /data/vendor/bpf ] && rm -rf /data/vendor/bpf/* 2>/dev/null

        # 9. Device tree overlays cleanup
        rm -f /data/vendor/dtbo/* 2>/dev/null
        rm -f /data/vendor/dtb/* 2>/dev/null

        # 10. Network configurations
        rm -f /data/vendor/netd/.*.configured 2>/dev/null

        # 11. Temporary files & logs
        rm -rf /data/local/tmp/kernel* 2>/dev/null
        rm -f /data/local/tmp/*.ko 2>/dev/null
        rm -f /data/local/tmp/kern_*.log 2>/dev/null
        rm -f /cache/kernel* 2>/dev/null
        rm -f /data/cache/kernel 2>/dev/null
        rm -f /data/bootconfig 2>/dev/null

        # 12. Old kernel init scripts
        rm -f /data/adb/service.d/templar_kernel_init.sh 2>/dev/null
        rm -f /data/adb/service.d/templar_power_daily.sh 2>/dev/null
        rm -f /data/local/tmp/templar_init.log 2>/dev/null
        rm -f /data/local/tmp/templar_power.log 2>/dev/null

        # 13. Sync to ensure all writes complete
        sync

        ui_print "  ✓ Persistent configs cleared"
    } 2>/dev/null
}

## Auto-detect and backup boot partition
backup_boot_image() {
    backup_dir="/sdcard/${KERNEL_NAME}Kernel_Backup"
    timestamp=$(date +%Y%m%d_%H%M%S)

    mkdir -p "$backup_dir" 2>/dev/null

    # Save current kernel info
    {
        echo "Previous Kernel Info"
        echo "===================="
        uname -a
        echo ""
        cat /proc/version
    } > "$backup_dir/${KERNEL_NAME}-PreviousKernel_${timestamp}.info" 2>/dev/null

    ui_print "→ Creating boot backup..."

    boot_partition=""
    detection_method=""

    # Method 1: Use $bootimg from ak3-core.sh (most reliable)
    if [ -n "$bootimg" ] && [ -b "$bootimg" ]; then
        boot_partition="$bootimg"
        detection_method="ak3-core"
    fi

    # Method 2: A/B slot detection
    if [ -z "$boot_partition" ]; then
        current_slot=$(getprop ro.boot.slot_suffix 2>/dev/null)
        if [ -n "$current_slot" ]; then
            for base in /dev/block/bootdevice/by-name /dev/block/by-name; do
                path="${base}/boot${current_slot}"
                if [ -b "$path" ]; then
                    boot_partition="$path"
                    detection_method="slot-$current_slot"
                    break
                fi
            done
        fi
    fi

    # Method 3: Direct by-name lookup (non-A/B)
    if [ -z "$boot_partition" ]; then
        for path in \
            /dev/block/bootdevice/by-name/boot \
            /dev/block/by-name/boot \
            /dev/block/platform/*/by-name/boot \
            /dev/block/platform/*/*/by-name/boot; do

            if [ -b "$path" ] 2>/dev/null; then
                boot_partition="$path"
                detection_method="by-name"
                break
            fi
        done
    fi

    # Method 4: MTK-specific paths
    if [ -z "$boot_partition" ]; then
        for path in \
            /dev/block/by-name/boot_para \
            /dev/block/mmcblk0boot0; do

            if [ -b "$path" ]; then
                boot_partition="$path"
                detection_method="mtk"
                break
            fi
        done
    fi

    # Execute backup
    if [ -n "$boot_partition" ] && [ -b "$boot_partition" ]; then
        backup_file="$backup_dir/${KERNEL_NAME}-Backup_${timestamp}.img"

        dd if="$boot_partition" of="$backup_file" bs=1M 2>/dev/null

        if [ -f "$backup_file" ]; then
            backup_size=$(stat -c%s "$backup_file" 2>/dev/null || echo 0)
            backup_mb=$((backup_size / 1048576))

            # Validate boot image (check ANDROID! magic header)
            if [ "$backup_size" -gt 1048576 ]; then
                magic=$(dd if="$backup_file" bs=8 count=1 2>/dev/null)
                if [ "$magic" = "ANDROID!" ] || [ "$backup_size" -gt 10485760 ]; then
                    ui_print "  ✓ Backup: ${backup_mb}MB ($detection_method)"

                    # Save metadata
                    {
                        echo ""
                        echo "Backup Info"
                        echo "==========="
                        echo "Boot partition: $boot_partition"
                        echo "Detection method: $detection_method"
                        echo "Backup file: ${KERNEL_NAME}-Backup_${timestamp}.img"
                        echo "Backup size: ${backup_mb}MB"
                        echo "Timestamp: $(date)"
                    } >> "$backup_dir/${KERNEL_NAME}-PreviousKernel_${timestamp}.info"
                else
                    ui_print "  ✗ Backup invalid (bad magic)"
                    rm -f "$backup_file"
                fi
            else
                ui_print "  ✗ Backup too small (${backup_mb}MB)"
                rm -f "$backup_file"
            fi
        else
            ui_print "  ✗ Backup creation failed"
        fi
    else
        ui_print "  ! Boot partition not found"
        ui_print "    Kernel info saved, boot backup skipped"
    fi
}

## Version check
check_kernel_version() {
    current_kernel=$(uname -r 2>/dev/null | cut -d'-' -f1 | cut -d'.' -f1-2)
    [ -z "$current_kernel" ] && current_kernel="unknown"

    ui_print "→ Checking kernel image..."

    # Check if kernel image exists in AnyKernel directory
    kernel_img=""
    for img in "$home"/Image "$home"/Image.gz "$home"/Image.lz4 "$home"/Image-dtb "$home"/Image.gz-dtb; do
        if [ -f "$img" ]; then
            kernel_img="$img"
            ui_print "  ✓ Found: $(basename $img)"
            break
        fi
    done

    if [ -z "$kernel_img" ]; then
        ui_print "  ✗ ERROR: Kernel image not found in zip"
        ui_print "  Expected: Image or Image.gz or Image.lz4"
        ui_print "  Files in directory:"
        ls -la "$home"/ 2>/dev/null | grep -i image || ls -la "$home"/
        exit 1
    fi

    # Get file size
    kernel_size=$(stat -c%s "$kernel_img" 2>/dev/null || echo 0)
    kernel_mb=$((kernel_size / 1048576))
    ui_print "  Size: ${kernel_mb}MB"

    if [ "$kernel_size" -lt 5242880 ]; then
        ui_print "  ✗ ERROR: Kernel image too small (< 5MB)"
        exit 1
    fi

    # Try to detect kernel version from image
    version_line=$(strings "$kernel_img" 2>/dev/null | grep -E "^Linux version [0-9]" | head -1)

    if [ -n "$version_line" ]; then
        # Extract version: "Linux version 6.18.32-Templar..." -> "6.18.32"
        full_version=$(echo "$version_line" | awk '{print $3}' | cut -d'-' -f1)
        new_kernel_string=$(echo "$full_version" | cut -d'.' -f1-2)

        ui_print "  Kernel: $full_version"
    else
        # Version string not embedded — proceed anyway (image size already validated)
        ui_print "  ! Version string not found, skipping version report"
        new_kernel_string="unknown"
    fi

    ui_print "→ Version check: $current_kernel → $new_kernel_string"

    # Accept any GKI version (5.x, 6.x, upstream). Image presence + size
    # already validated above; kernel version is informational only.
    new_major=$(echo "$new_kernel_string" | cut -d'.' -f1)
    case "$new_major" in
        [0-9]*) ui_print "  ✓ GKI kernel ${new_kernel_string} accepted" ;;
        *)      ui_print "  ! Version undetermined, flashing anyway" ;;
    esac
}

## Post-install validation
post_install_check() {
    ui_print "→ Validating installation..."

    # Check if any kernel image exists in AnyKernel directory
    kernel_found=0
    for img in "$home"/Image "$home"/Image.gz "$home"/Image.lz4 "$home"/Image-dtb "$home"/Image.gz-dtb; do
        if [ -f "$img" ]; then
            kernel_size=$(stat -c%s "$img" 2>/dev/null || echo 0)
            kernel_mb=$((kernel_size / 1048576))

            if [ "$kernel_size" -gt 5242880 ]; then
                ui_print "  ✓ Kernel: $(basename $img) (${kernel_mb}MB)"
                kernel_found=1
                break
            fi
        fi
    done

    if [ "$kernel_found" -eq 0 ]; then
        ui_print "  ✗ ERROR: No valid kernel image found"
        ui_print "  Installation may have failed"
        ui_print "  Files in zip:"
        ls -lh "$home"/ | grep -E "Image|\.ko$" || ls -lh "$home"/
        exit 1
    fi
}

## Post-boot script setup
set_postflash_configs() {
    mkdir -p /data/adb/service.d 2>/dev/null

    cat > /data/adb/service.d/templar_kernel_init.sh << 'EOF'
#!/system/bin/sh
LOGFILE="/data/local/tmp/templar_init.log"

# Wait for boot complete
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# Additional stabilization delay
sleep 15

{
    echo "========================================"
    echo "Templar Kernel Post-Boot Init"
    echo "$(date)"
    echo "========================================"
    echo ""

    echo "System Info:"
    echo "  Kernel: $(uname -r)"
    echo "  Android: $(getprop ro.build.version.release)"
    echo "  Security patch: $(getprop ro.build.version.security_patch)"
    echo ""

    echo "CPU Info:"
    cat /proc/cpuinfo | grep -E "Hardware|processor" | head -5
    echo ""

    echo "I/O Schedulers:"
    for q in /sys/block/*/queue/scheduler; do
        [ -f "$q" ] && echo "  $(basename $(dirname $(dirname $q))): $(cat $q | grep -o '\[.*\]' | tr -d '[]')"
    done
    echo ""

    echo "CPU Governors:"
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if [ -f "$cpu" ]; then
            cpu_num=$(echo "$cpu" | grep -o 'cpu[0-9]*' | head -1)
            echo "  $cpu_num: $(cat $cpu)"
        fi
    done | head -4
    echo ""

    echo "Memory Info:"
    free -h | grep -E "Mem:|Swap:"
    echo ""

    # No drop_caches here: it throws away the page cache the boot just
    # populated, so every app re-reads from flash -- slower AND more power.

    echo "========================================"
    echo "✓ Post-boot init complete"
    echo "========================================"

    # Self-destruct after successful run
    sleep 5
    rm -f /data/adb/service.d/templar_kernel_init.sh
} > "$LOGFILE" 2>&1

# Set readable permissions
chmod 644 "$LOGFILE" 2>/dev/null
EOF

    # Magisk/KernelSU skip service.d scripts without the exec bit (X_OK)
    chmod 755 /data/adb/service.d/templar_kernel_init.sh 2>/dev/null

    # ---- Persistent power efficiency script (survives reboots) ----
    cat > /data/adb/service.d/templar_power_daily.sh << 'PWREOF'
#!/system/bin/sh
# Templar Kernel — Daily Power Efficiency Tuning
# Runs every boot (Magisk/KernelSU service.d). Do NOT delete — these are
# runtime settings, not persistent across reboots.
#
# Goal: cut idle/suspend drain by removing needless wakeups. It deliberately
# does NOT cap CPU frequency: capping makes each task take longer, RAISING
# busy% and hurting responsiveness — the wrong lever for battery.

# Wait for boot complete
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done
sleep 5

# write-if-exists: skip missing nodes silently (portable across SoCs)
w() { [ -f "$1" ] && echo "$2" > "$1" 2>/dev/null; }

{
    echo "Templar power tuning applied: $(date)"

    # --- VM: fewer background wakeups (existing, kept) ---
    w /sys/power/sync_on_suspend 0             # Android already syncs on suspend
    w /proc/sys/vm/compaction_proactiveness 0  # no periodic kcompactd wakeups
    w /proc/sys/vm/page_cluster 0              # zram: no readahead benefit
    w /proc/sys/vm/watermark_boost_factor 0    # LMKD handles memory pressure

    # --- VM: stretch periodic timers so the SoC stays in deep idle longer ---
    w /proc/sys/vm/stat_interval 10            # vmstat updater 1s -> 10s
    w /proc/sys/vm/dirty_writeback_centisecs 1500  # bg flusher 5s -> 15s

    # --- cpuidle: force TEO (safety net) ---
    # menu + teo both build in; menu outranks teo (rating 20>19) and wins if
    # the cmdline governor pick is ever lost -> shallow C-states -> idle drain.
    w /sys/devices/system/cpu/cpuidle/current_governor teo

    # --- cpuidle: clear USER-disabled idle states ---
    # A vendor tool or a previous kernel can leave deep states disabled, so a
    # cluster never powers off and its CPUs look "awake every few seconds".
    # Writing 0 clears only DISABLED_BY_USER; a driver-disabled state stays off.
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
        [ -f "$s" ] && echo 0 > "$s" 2>/dev/null
    done

    # --- Pin unbound/power-efficient workqueues to the little cluster ---
    # With workqueue.power_efficient=1 every WQ_POWER_EFFICIENT queue becomes
    # unbound and its worker can be placed on ANY cpu, so housekeeping work
    # wakes the big cores. Background work does not need them. Derived from
    # cpu_capacity so it is portable; skipped entirely if that is unavailable.
    WQ_CPUMASK=/sys/devices/virtual/workqueue/cpumask
    if [ -f "$WQ_CPUMASK" ]; then
        maxcap=0
        for c in /sys/devices/system/cpu/cpu*/cpu_capacity; do
            [ -f "$c" ] || continue
            v=$(cat "$c" 2>/dev/null) || continue
            [ "$v" -gt "$maxcap" ] 2>/dev/null && maxcap=$v
        done

        if [ "$maxcap" -gt 0 ]; then
            mask=0
            for c in /sys/devices/system/cpu/cpu*/cpu_capacity; do
                [ -f "$c" ] || continue
                v=$(cat "$c" 2>/dev/null) || continue
                # <=60% of the biggest cpu == little tier on 2- and 3-tier SoCs
                [ $((v * 100 / maxcap)) -le 60 ] || continue
                n=$(basename "$(dirname "$c")" | tr -dc 0-9)
                mask=$((mask | (1 << n)))
            done
            # Never write an empty mask (uniform-capacity SoC, or parse failure).
            [ "$mask" -gt 0 ] && printf '%x\n' "$mask" > "$WQ_CPUMASK" 2>/dev/null
        fi
    fi

    # --- khugepaged: 10s -> 30s scan interval ---
    # THP is madvise-only, so khugepaged still runs but has far less to do;
    # its scan is the wakeup, not the collapse work.
    w /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 30000

    # --- Reduce vblank IRQ off-delay 5s -> 1s ---
    # At 120Hz the default fires ~600 needless IRQs per idle transition; 1s
    # still covers fast consumer reconnects.
    for p in /sys/module/drm/parameters/vblankoffdelay \
             /sys/module/msm_drm/parameters/vblankoffdelay; do
        [ -f "$p" ] && echo 1000 > "$p" 2>/dev/null && break
    done

    # --- Boeffla wakelock blocker: kill VENDOR suspend-abort wakeups ---
    # This is THE lever for reaching deep sleep / ~10mA idle: if suspend keeps
    # aborting, a vendor wakeup source is holding the AP awake. The in-kernel
    # curated default list is already active; add DEVICE-SPECIFIC names below.
    # The report at the end of this log names the real culprits on THIS device.
    # LEAVE EMPTY until you have real names: a wrong name does nothing, and
    # blocking an alarm/timer/input source breaks notifications & alarms.
    EXTRA_WL=""
    BLK=/sys/class/misc/boeffla_wakelock_blocker/wakelock_blocker
    [ -n "$EXTRA_WL" ] && w "$BLK" "$EXTRA_WL"

    echo "Done"

    # --- Wakeup-source report (diagnostic only, no tuning) ---
    # Idle/deepsleep drain and "big cores wake every few seconds" are almost
    # always a vendor wakeup source, which no kernel config can name in
    # advance. Sample once the device has settled and log the top holders so
    # EXTRA_WL above can be filled in with real names.
    (
        sleep 300
        WS=/sys/kernel/debug/wakeup_sources
        [ -f "$WS" ] || exit 0
        echo ""
        echo "--- top wakeup sources @ $(date) ---"
        echo "name / active_count / total_time_ms / prevent_suspend_ms"
        # Columns: 1 name .. 2 active_count .. 7 total_time .. 10 prevent_suspend_time.
        # Sorted by prevent_suspend_time: that is the one that blocks deep sleep.
        awk 'NR>1 && ($10+0 > 0 || $7+0 > 0) { printf "%-32s %8s %12s %12s\n", $1, $2, $7, $10 }' "$WS" \
            | sort -k4 -rn | head -15
    ) >> /data/local/tmp/templar_power.log 2>&1 &
} >> /data/local/tmp/templar_power.log 2>&1
PWREOF

    chmod 755 /data/adb/service.d/templar_power_daily.sh 2>/dev/null
    ui_print "  ✓ Post-boot script created"
    ui_print "  ✓ Power efficiency script created"
}

## ==============================================
## MAIN INSTALLATION FLOW
## ==============================================

ui_print " "
ui_print "============================================"
ui_print "  ${KERNEL_NAME} Kernel Installer"
ui_print "  by ${KERNEL_AUTHOR}"
ui_print "============================================"
ui_print " "

# Version check
check_kernel_version

# Cleanup
deep_kernel_cleanup

# Begin boot install
ui_print "→ Preparing boot partition..."
split_boot

# Backup old boot
backup_boot_image

# Flash new kernel
ui_print "→ Flashing kernel..."
flash_boot
## End boot install

ui_print " "

# Validation
post_install_check

# Setup post-boot script
set_postflash_configs

ui_print " "
ui_print "============================================"
ui_print "  ✓ Installation Complete"
ui_print "============================================"
ui_print " "
ui_print "  Backup: /sdcard/${KERNEL_NAME}Kernel_Backup"
ui_print " "
ui_print "  NEXT STEPS:"
ui_print "  1. Reboot device"
ui_print "  2. Wait 2-3 minutes for init"
ui_print "  3. Check: /data/local/tmp/templar_init.log"
ui_print " "
ui_print "  If bootloop occurs:"
ui_print "  → Flash: ${KERNEL_NAME}-Backup_*.img"
ui_print "     from /sdcard/${KERNEL_NAME}Kernel_Backup"
ui_print " "
ui_print "============================================"
ui_print " "

## End of install
