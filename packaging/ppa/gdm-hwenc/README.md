# gdm-hwenc/ - PPA native source package

Native source-package wrapper for the optional
`gnome-remote-desktop-gdm-hwenc` udev rule.

The rule body remains canonical in
[`../../gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules`](../../gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules).
`build-source-packages.sh gdm-hwenc` copies that rule into the generated native
source tree before running `dpkg-buildpackage -S`.

This package is opt-in because it grants the `gdm` group access to the Rockchip
codec nodes so the pre-login greeter can hardware-encode RDP.
