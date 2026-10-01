# rfstag-kiosk

System integration for RFStag sign-in kiosks on **64-bit Raspberry Pi OS
(Trixie)**: the browser kiosk service, plus plug-and-play NFC readers.
Builds `rfstag-kiosk_<version>_all.deb`.

This replaces `nfcserver3` **for new images only**. The ~20 field units keep
running nfcserver3 from its own apt repo, untouched; they never have this
package installed, so their unattended upgrades never pick it up.

## Plug-and-play readers

| Reader | udev match | Service | Program (rfskiosk2) |
|---|---|---|---|
| Sony RC-S380 | USB `054c:06c1`/`06c3` | `sony-reader.service` | `nfckiosk` (reads + speaker beeps) |
| VTAP100 | tty `303a:4007` | `vtapreader@ttyACM0.service` (one per reader) | `vtapreader` |
| ACS ACR1552U | USB `072f:2401` | `acrreader.service` | `acrreader` (+ `rfstag-acsvas` bridge if installed) |

Plugging a reader in starts its service; unplugging stops it (`BindsTo=` the
device). Readers already attached at boot are started by udev's coldplug.
Different readers can run side by side. The reader services are never
enabled; only `launch_kiosk2.service` (the browser) is.

## What gets installed

```
/usr/bin/launch_kiosk2, writetags, check_pi.sh
/usr/lib/systemd/system/launch_kiosk2.service, sony-reader.service,
                        vtapreader@.service, acrreader.service
/usr/lib/udev/rules.d/60-rfstag-readers.rules
/usr/share/polkit-1/rules.d/50-rfstag-pcscd.rules   (pcscd access for user pi)
/etc/rfstag/base.env, nfcreader.ini                 (conffiles)
/usr/share/rfstag/sounds/*.wav                      (linked into ~pi/Music)
```

Per-kiosk settings go in `/home/pi/.config/rfstag/local.env` (written by
Ansible; see `/usr/share/doc/rfstag-kiosk/local-example.env`).

Not in this package (installed separately, by Ansible):

- **rfskiosk2** (pipx, as pi), pinned: `pipx install rfskiosk2==<ver> --pip-args="-c constraints.txt"`
- **rfstag-acsvas** + ACS `libacsccid1` driver (64-bit only; private, local .debs)

## Build

```
./build-deb.sh        # -> dist/rfstag-kiosk_<VERSION>_all.deb
```

Bump `VERSION` for each release.

## Test on a bench Pi

```
sudo apt install ./dist/rfstag-kiosk_*_all.deb
```

Then, for each reader, and for pairs of readers:

```
# plug in -> should become active within a few seconds
systemctl status sony-reader acrreader 'vtapreader@*'
journalctl -f -u sony-reader -u acrreader -u 'vtapreader@*'
# tap a tag / phone; then unplug -> service should go inactive
```

Also: reboot with readers attached (services start by themselves), and
replug each reader (service restarts).

Useful: `udevadm monitor --udev` while plugging, and
`systemctl list-dependencies dev-sony_reader.device`.

## Changes from nfcserver3

- New-style units only (`sony-reader` = nfckiosk with built-in beeper);
  no `nfcserver3`/`kiosk_beeper` legacy services
- One udev rules file; services stop on unplug
- Config moved from `/etc/profile.d/rfstag/` to `/etc/rfstag/`; ini no
  longer written into `/home/pi`
- `/etc/asound.conf` is no longer installed (nfcserver3 installed it as a
  directory by mistake, so it never took effect); kept as an example in docs
- `writetags` fixed (env syntax; `-w <brigade>` argument)
- `launch_kiosk2` uses `chromium` on Trixie, `chromium-browser` on Bookworm
- polkit rule so `acrreader` can use pcscd as user pi
- No crontab edits: weekly reboot / updates are configured by Ansible
