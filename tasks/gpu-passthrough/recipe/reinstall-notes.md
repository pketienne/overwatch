# Things That May Change After Reinstall

| Item | Why it might change | How to fix |
|---|---|---|
| PCI bus addresses (`03:00.0`) | Different kernel/BIOS enumeration | Check `lspci -nn`, update VM XML and vm-overwatch script |
| i2c device numbers (`/dev/i2c-4` through `/dev/i2c-10`) | Different driver probe order | Check `ls /sys/bus/i2c/devices/`, update vm-overwatch `fuser` lines |
| DRM card numbers (`/dev/dri/card0`, `card1`) | Different GPU probe order | Check `ls -la /dev/dri/by-path/` |
| Monitor connector names (`HDMI-3`, `DP-1`) | Different GPU/output enumeration | Check `xrandr --listmonitors`, update monitors.xml |
| virtio-win.iso path | VM XML references `/home/myuser/Downloads/virtio-win.iso` | Re-download ISO to same path, or update VM XML |
| Netplan config filename | Ubuntu installer may use different naming | Adjust bridge config to match |
