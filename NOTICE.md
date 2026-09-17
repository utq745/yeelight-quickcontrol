# Project provenance

Yeelight QuickControl was inspired by the open-source project
[Smart Lights for Yeelight](https://github.com/ishiharas/Smart-Lights-Yeelight/tree/e3df28c50d4c50144c8e8ddf6120a7104a141f89),
originally published by Michael Schulz (`ishiharas`) under the GNU General
Public License v3.0.

The current implementation is a ground-up rewrite by Utku Sakallıoğlu. It
replaces the original Angular/Electron application and `yeelight-platform`
dependency with a native Swift menu-bar wrapper, a dependency-free Node.js
controller, and a newly implemented HTML/CSS/JavaScript interface.

The projects necessarily share product concepts and Yeelight protocol method
names such as `set_power`, `set_bright`, `set_hsv`, and `set_ct_abx`. Those
names are part of the device protocol. No original Angular/Electron source file
is distributed in the current version.

Historical revisions in this Git repository may contain code from the original
GPL-3.0 project. Those revisions remain subject to their original license. The
new Yeelight QuickControl implementation at the current revision is licensed
under Apache-2.0 as described in `LICENSE.md`.

Yeelight is a trademark of its respective owner. This project is independent
and is not affiliated with or endorsed by Yeelight.
