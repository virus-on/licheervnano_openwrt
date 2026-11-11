# Hardware notes

## The board

The LicheeRV Nano WE is the Wi-Fi and Ethernet version of Sipeed's LicheeRV Nano. The port was developed on board revision
70418A. The closest published schematic is 70418, rev 1.4.

| Part | Detail |
| --- | --- |
| SoC | SOPHGO SG2002. Linux runs on the main C906 core at 850 MHz |
| RAM | 256 MB DDR3 in the SoC package. Linux sees about 236 MB |
| Storage | microSD |
| Ethernet | 10/100 from the SoC's MAC and internal PHY. The RJ45 jack is on a separate module that you solder to the board with a ribbon cable |
| Wi-Fi | AIC8800D on SDIO, one antenna connector |
| Button | User button on GPIOA30, used for factory reset and failsafe |
| Power | USB-C, 5 V |

Sipeed advertises the C906 at 1 GHz. That speed is the boot loader's overdrive mode, which also raises the core voltage, and
this board can't change its core voltage: the voltage-control resistor (R140, `PWR_PWM`) isn't fitted. The vendor boot
loader runs the core at 850 MHz, and this port leaves it there.

The schematic labels the antenna feed `2.4G`, but the radio works on 5 GHz too. It was tested at channel 40, HE20.

## Serial console

UART0 is on pins A16 (board TX) and A17 (board RX), at 115200 baud, 3.3 V logic. Connect:

| Adapter | Board |
| --- | --- |
| TX | A17 |
| RX | A16 |
| GND | GND |

Leave the adapter's VCC unconnected and power the board over USB-C. The boot ROM prints a few lines at a different baud
rate before the boot loader starts, so some garbage at power-on is normal.

A CH341A programmer in serial mode worked. Typing quickly into the console drops characters, so paste long commands slowly.

## Boot chain

1. The boot ROM reads `fip.bin` from the first FAT partition of the SD card.
2. `fip.bin` holds the first-stage loader, which sets up clocks and DRAM, then OpenSBI 0.9 and U-Boot 2021.10.
3. U-Boot sets the Wi-Fi SDIO pin muxing and the Wi-Fi power GPIO, decodes `logo.jpeg`, and loads `boot.sd` from the same
   partition.
4. `boot.sd` is a FIT image with an LZMA-compressed kernel and the device tree. U-Boot boots its configuration named
   `config-sg2002_licheervnano_sd`, so the port uses that name.
5. The kernel mounts the root filesystem from partition 2.

All of these come from Sipeed's release unchanged. The port's device tree relies on U-Boot for the Wi-Fi pin muxing.

## SD card layout

| Partition | Size | Contents |
| --- | --- | --- |
| 1, FAT | 64 MB | `fip.bin`, `boot.sd`, `logo.jpeg` |
| 2 | 256 MB | squashfs root, with the writable overlay after it |

The overlay is F2FS, created on first boot in the space after the squashfs image. A factory reset formats it again. Space on
the card beyond these 320 MB is unused.

## Boot files

The target patch carries two files from Sipeed's 2025-12-30 SD card image, unmodified:

| File in the patch | On the card | SHA-256 |
| --- | --- | --- |
| `target/linux/sophgo/image/fip/licheerv-nano-20251230.bin` | `fip.bin` | `ead936116224c25467917859594d6f5f9af2fa883b52e19be86c780ff770494d` |
| `target/linux/sophgo/image/fip/logo.jpeg` | `logo.jpeg` | `fa702818ed2fe4e04c78a1d9b9ea3ed2bb96ed3f16c0dc1fd7768e990e5cf4cc` |

The board needs `logo.jpeg` to reboot. U-Boot decodes it on every boot, and when it's missing, U-Boot decodes whatever is in
memory. After a warm reboot that crashes U-Boot in a loop.

To get both files from Sipeed yourself (needs `mtools`):

```bash
wget https://github.com/sipeed/LicheeRV-Nano-Build/releases/download/20251230/2025-12-30-20-00-6073d5.img.xz
xz -dk 2025-12-30-20-00-6073d5.img.xz
# Partition 1 starts at sector 1 in this image. Check with: sfdisk -d 2025-12-30-20-00-6073d5.img
mcopy -n -i 2025-12-30-20-00-6073d5.img@@512 ::fip.bin ::logo.jpeg .
sha256sum fip.bin logo.jpeg
```

The checksums should match the table. The U-Boot, OpenSBI and first-stage loader sources are in
[sipeed/LicheeRV-Nano-Build](https://github.com/sipeed/LicheeRV-Nano-Build).
