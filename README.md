# OpenWrt for the Sipeed LicheeRV Nano WE

OpenWrt with LuCI for the [Sipeed LicheeRV Nano WE](https://wiki.sipeed.com/hardware/en/lichee/RV_Nano/1_intro.html), a
SOPHGO SG2002 board with Ethernet and AIC8800 Wi-Fi. It turns the board into a pocket router: Ethernet is the WAN, Wi-Fi is
the LAN, and it can also use another Wi-Fi network as its uplink.

It runs OpenWrt `main` from November 2026 on mainline Linux 6.18, not the vendor's 5.10 kernel. The only vendor binaries are the boot
loader (`fip.bin`) and the Wi-Fi firmware.

## Status

Everything below was tested on one board, revision 70418A.

| Feature | State |
| --- | --- |
| Boot from SD card, serial console | Works |
| Ethernet WAN, DHCP from the upstream router | Works, see [known issues](docs/known-issues.md) |
| Wi-Fi access point, 2.4 and 5 GHz, WPA2 and WPA3, Wi-Fi 6 rates | Works |
| DHCP, NAT and firewall for Wi-Fi clients | Works, about 40 Mbit/s |
| LuCI web interface | Works |
| Settings survive reboot and `sysupgrade` | Works |
| Factory reset, from LuCI or the user button | Works |
| Travel-router mode, Wi-Fi uplink with travelmate | Works, about 12 Mbit/s |
| `reboot` | Works |
| Bluetooth, camera, NPU, display, audio, USB | Not supported |

The [known issues](docs/known-issues.md) page lists what doesn't work well, and [porting notes](docs/porting.md) explain
how the port was put together.

## Build

The build is tested on Ubuntu 22.04. It needs about 25 GB of disk and an hour or two on a fast machine, most of it spent
building the toolchain the first time. Don't build as root, and keep the checkout on a path without spaces.

Install the build dependencies:

```bash
sudo apt update
sudo apt install build-essential clang flex bison g++ gawk gettext git libncurses-dev libssl-dev \
    python3-distutils python3-setuptools rsync swig unzip zlib1g-dev file wget
```

Clone and build:

```bash
git clone https://github.com/virus-on/licheervnano_openwrt.git
cd licheervnano_openwrt
./build.sh
```

The image lands in `output/`:

| File | Contents |
| --- | --- |
| `licheervnano-openwrt-<date>-sdcard.img.gz` | SD card image, also used for upgrades |
| `licheervnano-openwrt-<date>-sdcard.img.gz.sha256` | Checksum |
| `wifi-password.txt` | Wi-Fi password baked into this image |

Each build generates its own random Wi-Fi password. To choose one, set `WIFI_KEY` before the `wifi-key` stage runs, for
example `WIFI_KEY=my-password ./build.sh`.

### Stages

`build.sh` works in stages and remembers which ones finished, in `.build/`. Running it again skips finished stages, so a
failed build picks up where it stopped.

| Stage | What it does |
| --- | --- |
| `submodules` | Fetches OpenWrt and its five feeds at the pinned commits |
| `patches` | Puts `openwrt` on a local branch `licheervnano` at the pin and applies `patches/openwrt` |
| `feeds` | Points OpenWrt at the feed submodules and installs their packages |
| `config` | Loads `configs/licheervnano.seed` |
| `wifi-key` | Writes the Wi-Fi password into `openwrt/files/` |
| `image` | Downloads sources and builds the image |

`./build.sh --redo <stage>` reruns a stage and every stage after it, and `./build.sh --status` shows what's done. Changes you
make inside `openwrt/` stay put until you redo `patches`, which resets OpenWrt's tracked files to the pin.

To change the package selection, run `make -C openwrt menuconfig`, then `./build.sh --redo image`. Redoing `config` loads
the seed again and drops your menuconfig changes.

### Building by hand

`build.sh` runs these steps, from the repository root:

```bash
git submodule update --init --depth 1
git -C openwrt checkout -B licheervnano "$(git ls-files -s openwrt | awk '{print $2}')"
git -C openwrt am --keep-cr ../patches/openwrt/*.patch
for f in packages luci routing telephony video; do echo "src-link $f $PWD/feeds/$f"; done > openwrt/feeds.conf
cd openwrt
./scripts/feeds update -a && ./scripts/feeds install -a
cp ../configs/licheervnano.seed .config && make defconfig
mkdir -p files/etc && echo 'your-wifi-password' > files/etc/licheewrt-wifi-key
make -j"$(nproc)"
```

`--keep-cr` matters: the AIC8800 package carries patches for source files with Windows line endings, and without it `git am`
strips them and the driver fails to build. `git am` also needs a Git name and email to be configured. The image is
`openwrt/bin/targets/sophgo/generic/openwrt-sophgo-generic-sipeed_licheerv-nano-we-squashfs-sdcard.img.gz`.

### Following newer OpenWrt

OpenWrt and the feeds are pinned to the commits this port was tested with. To build on the latest `main` instead:

```bash
git submodule update --remote --depth 1
git add openwrt feeds
./build.sh --redo patches
```

Newer OpenWrt can move to a different kernel or change the APIs the patches touch, so expect to fix patches. To go back to
the pins:

```bash
git reset -q openwrt feeds
./build.sh --redo submodules
```

## Flash

Write the image to a microSD card. On Linux, with the card at `/dev/sdX`:

```bash
gzip -dc output/licheervnano-openwrt-*-sdcard.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

On Windows or macOS, [balenaEtcher](https://etcher.balena.io/) writes the `.img.gz` directly.

## First boot

1. Insert the card, connect Ethernet to your upstream router, and power the board over USB-C. Boot takes about 30 seconds,
   and the Wi-Fi network appears about 15 seconds after that.
2. Join the Wi-Fi network `LicheeWRT` with the password from `wifi-password.txt` or the release notes.
3. Open <http://192.168.8.1>. The root password is empty, so LuCI logs you in and warns you to set one. Set it under
   System, Administration. Until you do, anyone on the Wi-Fi can log in, over SSH too.
4. Change the Wi-Fi password under Network, Wireless. Every copy of a published image shares the same password.

The LAN is `192.168.8.1/24`, so it doesn't clash with an upstream router on `192.168.1.x`. The Wi-Fi country is set to `UA`.
Set your own under Network, Wireless, Advanced settings.

A serial console runs at 115200 baud. See [hardware notes](docs/hardware.md) for the wiring.

## Upgrade

Upgrade with the `.img.gz` from a newer build. Settings are kept. Over SSH, copy the image to `/tmp`, then:

```bash
sysupgrade -v /tmp/licheervnano-openwrt-<date>-sdcard.img.gz
```

LuCI's System, Backup / Flash Firmware, Flash image runs the same `sysupgrade`. The board reboots and comes back in about a
minute.

## Factory reset

Hold the user button for more than 5 seconds, then release it. A press shorter than a second reboots instead. LuCI's System, Backup / Flash
Firmware, Perform reset, and `firstboot -y && reboot` over SSH do the same. The Wi-Fi goes back to `LicheeWRT` with the
image's password.

Holding the button while the board powers up starts failsafe mode, OpenWrt's recovery shell.

## Travel-router mode

The board can use another Wi-Fi network as its uplink and keep serving `LicheeWRT`. Set it up in LuCI under Services,
Travelmate. The single radio serves both networks, which has two effects. Clients get about 12 Mbit/s. And `LicheeWRT` moves
to the uplink's channel, and its band. When Ethernet is also connected, it takes priority over the Wi-Fi uplink.

## Repository layout

| Path | Contents |
| --- | --- |
| `patches/openwrt/` | The port, as three patches against OpenWrt: the `sophgo` target and board, the AIC8800 driver package, a fix to OpenWrt's `wifi-scripts` |
| `configs/licheervnano.seed` | Build configuration |
| `openwrt/`, `feeds/` | OpenWrt and its feeds, as pinned submodules |
| `build.sh` | The build |
| `docs/` | Hardware notes, porting notes and known issues |

The target patch includes two vendor files, `fip.bin` and `logo.jpeg`.
[Hardware notes](docs/hardware.md#boot-files) explain where they come from and how to extract them yourself.

## Licence and credits

GPL-2.0-only, the same as OpenWrt. See [LICENSE](LICENSE).

- The AIC8800 package is ImmortalWrt's packaging, by way of
  [akorshun/aic8800-openwrt](https://github.com/akorshun/aic8800-openwrt), and builds
  [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800).
- `fip.bin` and `logo.jpeg` are Sipeed's, from the
  [LicheeRV-Nano-Build](https://github.com/sipeed/LicheeRV-Nano-Build) 2025-12-30 release.
- The Ethernet PHY tuning is ported from Sipeed's vendor kernel driver.

The port was developed with [Claude Code](https://claude.com/claude-code). The commits carry its co-author trailer.
