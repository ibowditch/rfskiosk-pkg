#!/usr/bin/env bash
# Builds dist/rfstag-kiosk_<VERSION>_all.deb. Runs anywhere with dpkg-deb
# (Debian/Ubuntu dev machine or a Pi): nothing here is compiled.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PKG=rfstag-kiosk
VERSION="$(tr -d ' \n' < VERSION)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
R="$STAGE/$PKG"

# Programs
install -D -m 0755 bin/launch_kiosk2  "$R/usr/bin/launch_kiosk2"
install -D -m 0755 bin/writetags      "$R/usr/bin/writetags"
install -D -m 0755 bin/check_pi.sh    "$R/usr/bin/check_pi.sh"

# Services (reader units have no [Install]: udev starts them)
for u in systemd/*.service; do
    install -D -m 0644 "$u" "$R/usr/lib/systemd/system/$(basename "$u")"
done

# Reader hot-plug rules, pcscd access for user pi
install -D -m 0644 udev/60-rfstag-readers.rules  "$R/usr/lib/udev/rules.d/60-rfstag-readers.rules"
install -D -m 0644 polkit/50-rfstag-pcscd.rules  "$R/usr/share/polkit-1/rules.d/50-rfstag-pcscd.rules"

# Config (conffiles: dpkg keeps local edits on upgrade)
install -D -m 0644 conf/base.env       "$R/etc/rfstag/base.env"
install -D -m 0644 conf/nfcreader.ini  "$R/etc/rfstag/nfcreader.ini"

# Sounds and docs
for w in sounds/*.wav; do
    install -D -m 0644 "$w" "$R/usr/share/rfstag/sounds/$(basename "$w")"
done
install -D -m 0644 conf/local-example.env    "$R/usr/share/doc/$PKG/local-example.env"
install -D -m 0644 conf/asound.conf.example  "$R/usr/share/doc/$PKG/asound.conf.example"
install -D -m 0644 README.md                 "$R/usr/share/doc/$PKG/README.md"

# Package metadata
install -d "$R/DEBIAN"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SIZE@/$(du -sk "$R" | cut -f1)/" \
    packaging/control.in > "$R/DEBIAN/control"
printf '/etc/rfstag/base.env\n/etc/rfstag/nfcreader.ini\n' > "$R/DEBIAN/conffiles"
for s in postinst prerm postrm; do
    install -m 0755 "packaging/$s" "$R/DEBIAN/$s"
done

mkdir -p dist
OUT="dist/${PKG}_${VERSION}_all.deb"
dpkg-deb --root-owner-group --build "$R" "$OUT"
echo "Built $OUT"
