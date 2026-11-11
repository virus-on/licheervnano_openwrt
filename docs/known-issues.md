# Known issues

## Ethernet link drops

On the test unit, the Ethernet link goes down for about 3 seconds roughly once a minute. The drops come in bursts, and a
quarter of them happen within 5 seconds of the link coming back. Some stretches have none for hours: one overnight run went
8 hours without a drop, then climbed to about 14 drops per 10 minutes by morning. Downloads stall during a drop.

To see how often it happens on your board, look for `eth0: Link is Down` in the kernel log, or read the count since boot:

```bash
cat /sys/class/net/eth0/carrier_down_count
```

## Wi-Fi client throughput is about 40 Mbit/s

Clients get about 40 Mbit/s through the router, sometimes up to 48. The CPU is the limit. Clients link at up to 115
Mbit/s, and while routing at full speed the CPU is 70 to 80% busy, half of it in packet processing.
[Porting notes](porting.md#performance) list what was tried.

## Transmit power shows 0 dBm

`iw dev` and LuCI report the radio's transmit power as 0 dBm. It's a reporting quirk of the driver. The radio transmits
normally, and a client next to the board sees it at about -37 dBm.
