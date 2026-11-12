# Porting notes

How OpenWrt was brought up on the LicheeRV Nano WE, in roughly the order it happened. The code is in
[`patches/openwrt`](../patches/openwrt).

## Starting point

OpenWrt had no target for any SOPHGO chip. The usual community route for these boards is the vendor's Linux 5.10 tree,
which ties OpenWrt to a 2020 kernel and a pile of prebuilt binaries. Mainline Linux has been picking up SG2002 support,
though, and 6.18 already has the clocks, pin control, SD card host and Ethernet MAC. OpenWrt's `d1` target (another RISC-V
SoC) was already on 6.18, so the new `sophgo` target copies its structure and kernel config as a base.

The plan was to keep everything mainline except the pieces that had no choice. Two vendor pieces remain: the boot loader
and the Wi-Fi driver.

## Booting the vendor boot loader

Building a boot loader from source was not attempted. Earlier community ports had trouble with self-built boot files on
these chips, and Sipeed's `fip.bin` works. The port puts it on a FAT partition with a FIT image built the way U-Boot
expects:

- U-Boot boots the configuration called `config-sg2002_licheervnano_sd` and nothing else, so the FIT uses that name.
- U-Boot loads `boot.sd` into a 16 MiB buffer at `0x81800000` and runs the kernel at `0x80200000`. An uncompressed 6.18
  kernel doesn't fit the buffer, so the kernel is LZMA-compressed inside the FIT. The image recipe checks both sizes,
  because a kernel that grows past `0x81800000` would overwrite the FIT while unpacking.
- U-Boot passes `loglevel=0`, which hides even kernel panics. The kernel appends `loglevel=4 panic=10` to the command line,
  so warnings show on the console and a panic reboots after 10 seconds.
- `clk_ignore_unused` stops Linux from turning off clocks that U-Boot set up and no driver claims yet.
- The top 2 MiB of DRAM stay out of Linux's memory map, as in the vendor's layout.

## Device tree

The WE's device tree includes mainline's LicheeRV Nano-B tree and adds:

- SDIO for Wi-Fi on `sdhci1`, at 25 MHz with 3.3 V signalling, which is what the vendor tree uses. The card can't be removed.
- An `mmc-pwrseq-simple` power sequence on GPIOA26, the Wi-Fi chip's power enable.
- Ethernet: the MAC, the MDIO bus and the internal PHY, with the efuse clocks the PHY driver needs.
- The user button on GPIOA30 as `gpio-keys`, active low, sending `KEY_RESTART`.
- A restart controller node.

The Wi-Fi pins get their mux settings from U-Boot, so the tree has no pin control for them.

## Wi-Fi

The AIC8800 has no driver in Linux. The package comes from
[akorshun/aic8800-openwrt](https://github.com/akorshun/aic8800-openwrt), ImmortalWrt's packaging of the
[radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) driver, written for arm64 and OpenWrt 25.12. It built for riscv64
once one patch was added: Linux 6.18 changed several `cfg80211` operations to take a `wireless_dev`, and changed the TDLS
structures. The chip on this board loads the `u03` firmware set.

Two problems showed up on the first boots.

The radio's sysfs path includes the SDIO card's address, which is random on every boot. OpenWrt identifies a radio by that
path, so after a reboot the configured radio no longer matched any hardware and Wi-Fi stayed off. The port binds the radio
by its name, `phy0`, instead.

OpenWrt normally writes its first-boot settings from `uci-defaults` scripts, but the radio only appears once the driver has
loaded its firmware, after those scripts have run. The access point is configured from an `ieee80211` hotplug script
instead, which runs when the radio appears: `LicheeWRT`, WPA2, 2.4 GHz channel 6, with the password baked into the image.

## LAN and DHCP

The board has one Ethernet port, which is the WAN. The LAN is a bridge with only the Wi-Fi in it, at `192.168.8.1/24`.

On the first image, Wi-Fi clients got `169.254.x.x` addresses. OpenWrt's DHCP server only turns itself on for a LAN that
the board's `board.json` declares as static, and the board file only declared the WAN. It now declares both.

## Ethernet PHY

With mainline's generic PHY driver the link came up at 100 Mbit/s, but traffic routed to the internet ran at 2.1 Mbit/s,
and the link dropped 40 times in 12 minutes. Mainline doesn't touch the internal PHY's analog settings. The vendor kernel
does: its PHY driver writes transmit levels, termination, filter coefficients and calibration values from the chip's
efuses. The port includes that setup as `cvitek-ephy.c`. With it, downloads from the router ran at 52 Mbit/s.

The link drops didn't go away, though (see [known issues](known-issues.md)), and later testing showed that the generic
driver drops at a similar rate. Changing the tuning live didn't help either. Over alternating 3-minute runs, the vendor's
default transmit settings dropped the link about 2.5 times as often as the efuse calibration, and changing termination or
bias current alone was no better. The vendor driver's other receive filter set, meant for the CV180x, stopped reception
completely. The efuse calibration is the best of what was tried, and it's what the driver uses.

## Reboot

`reboot` shut the system down and then hung. The vendor OpenSBI offers no reset for this chip, and mainline has no restart
driver for it. `sophgo-reboot.c` registers a restart handler that triggers the RTC block's warm reset at `0x05025000`, an
approach taken from an earlier community CV18xx port.

That exposed a second problem: after a warm reset, U-Boot crashed in a loop. U-Boot decodes a boot logo on every boot, and
the first image had none, so it decoded whatever was in memory. After a cold boot that memory is noise and the decoder gives
up. After a warm reset it still holds Linux's data, and the decoder crashes. Shipping Sipeed's `logo.jpeg` fixed it.

## Root filesystem and upgrades

The first images used an ext4 root. The release uses a squashfs root with a writable F2FS overlay, so a factory reset can
always get back to the image's contents. OpenWrt's `fstools` puts the overlay in the free space after the squashfs image, at
the next 64 KiB boundary. The image recipe zeroes 1 MiB there, so writing a new image always starts with a fresh overlay.

The image's root partition is 256 MB, which left about 200 MB for the overlay. A preinit script, `79_grow_rootfs`, grows
the partition to the end of the card before `mount_root` runs. It rewrites the partition's length in the MBR, then has the
kernel resize the partition with `partx`, which works while the squashfs is mounted from it. If the resize fails, the script
reboots and the kernel reads the new table at boot. `fstools` sets up the overlay's loop device after that and formats it
at the full size: on a 32 GB card, that's a 29.6 GB overlay, formatted in about 6 seconds. The script only grows the last
partition of a DOS partition table, and only when the table matches what the kernel sees.

Upgrades use OpenWrt's existing `legacy-sdcard` helpers. When the image's partition table matches the card's, they write
the boot and root partitions from the `.img.gz`. Once the root partition has grown, the tables differ, so they write the
whole image, partition table included, and the next boot grows the partition again before the new overlay is formatted.
Settings travel across the upgrade on the FAT boot partition: `sysupgrade` saves them there, and a preinit script moves
them back on the next boot. For this to work:

- FAT support is built into the kernel, so the preinit script can mount the boot partition without loading modules. The
  first images had no FAT support at all, which also meant the boot partition couldn't be updated from a running system.
- The metadata `sysupgrade` checks is appended after gzip. Appended before, it ends up inside the compressed stream, where
  the check can't read it.

The first upgrade test found that the first-boot scripts ran again after an upgrade. The WAN got a new random MAC address
and a firewall rule from the development build was added twice. The AP script would have put the default Wi-Fi password back. Each script now checks
whether its settings already exist. The AP script's marker is a `wireless` option, so it survives upgrades and goes away on
factory reset.

## Reset button

The button needs `kmod-gpio-button-hotplug`, which reads `gpio-keys` itself and feeds OpenWrt's button scripts.
`kmod-button-hotplug`, tried first, only forwards input events and never triggered anything.

## Travel-router mode

The driver allows one access point and one client interface on the radio at the same time, so the board can join another
Wi-Fi network as its uplink and keep serving its own. `travelmate` and its LuCI page are included for managing uplinks.

Adding a client interface broke the access point every time. OpenWrt's `wifi-scripts` reuse an existing network interface
when setting up a new one, and `find_reusable_wdev()` treated any interface whose operational state was `down` as free. This
driver's access point stays `down` for about 5 seconds while it applies the country setting, so the client setup took over
hostapd's interface. The fix only reuses an interface that is also administratively down. With it, three restarts out of
three brought both networks up, against none before. This bug is in OpenWrt itself and probably affects other slow drivers.

Both networks share one radio, so the access point has to follow the uplink's channel, and each packet crosses the air twice.
Clients got 11.5 to 12.5 Mbit/s through a Wi-Fi uplink.

## Performance

Wi-Fi clients get about 40 Mbit/s through the router. The CPU is the limit: traffic that ends at the router itself reaches 53
to 60 Mbit/s, and while routing, about half of the CPU time goes to packet processing in software interrupts.

- Software flow offloading is on by default. It raised routed downloads from 38.0 to 41.2 Mbit/s on average.
- Kernel debugging options inherited from the `d1` config (`SLUB_DEBUG`, `RCU_TRACE`) are off. That gave no gain that could
  be measured over the noise of internet downloads.
- The core runs at 850 MHz, not the advertised 1 GHz. The [hardware notes](hardware.md#the-board) explain why.

The SDIO clock stays at the vendor's 25 MHz. With the CPU running out first, a faster bus wasn't tried.
