# gdm-hwenc/ - PPA native source package

Native source-package wrapper for the optional
`gnome-remote-desktop-gdm-hwenc` udev rule.

The rule body remains canonical in
[`../../gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules`](../../gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules).
`build-source-packages.sh gdm-hwenc` copies that rule into the generated native
source tree before running `dpkg-buildpackage -S`.

This package is opt-in because it grants the `gdm` group access to the Rockchip
codec nodes so the pre-login greeter can hardware-encode RDP.

Current PPA state: the source wrapper is tracked and buildable, but it has not
been uploaded to any of the six PPAs. Upload remains gated on choosing to widen
codec access to the `gdm` group and validating the normal GRD system stack.
