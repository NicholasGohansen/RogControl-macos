# RogControl for macOS: ASUS TUF Gaming F15 FX507VV port

A port of [pengubow/RogControl-macos](https://github.com/pengubow/RogControl-macos) (written for the
ROG Strix G17 G713PV, Ryzen 9 7945HX) to the **ASUS TUF Gaming F15 FX507VV**
(Intel Core i7-13620H, RTX 4060 Laptop) running macOS on OpenCore.

`RogControl.kext` is a VirtualSMC plugin that talks to the firmware through ASUS WMI
(`\_SB.ATKD.WMNB`), the same calls Linux `asus-wmi` / G-Helper make. This fork changes the
parts that were specific to the Strix: the ACPI side, the keyboard lighting and the menu bar app.
All credit for the original design goes to the upstream project; see `README.upstream.md`.

> Check the upstream licence before redistributing. This fork inherits whatever terms the upstream
> project has.

## Status

Tested on one machine: ASUS TUF F15 FX507VV, macOS Tahoe 26.7.1, OpenCore, VirtualSMC and Lilu.

| Feature | State |
|---|---|
| Fan RPM and CPU/GPU temperatures (SMC keys, menu bar) | Works |
| Performance modes Silent / Balanced / Turbo, also on Fn+F5 | Works |
| Battery charge limit | Works |
| Keyboard backlight level, Fn+F2 / Fn+F3 | Works (through WMI) |
| Keyboard RGB colour and effects (`tufrgb`, Fn+F4 presets) | Works (single zone) |
| Menu bar app (profile, backlight, charge limit, colour) | Rewritten to call `rogctl` / `tufrgb`; build it and see |
| Fn+F10 touchpad toggle, Fn+F11 sleep | Key codes seen, not verified |
| Custom fan curves, PL1/PL2/FPPT, NVIDIA dynamic boost | Not tested here |
| CPU frequency cap (AMD CPPC) | Not applicable (Intel), disabled |
| Per-zone Aura lighting, `rogd` + `install.sh` config | Not ported (Strix / Ryzen defaults) |

## What changed from upstream

- **`acpi/SSDT-ROG.dsl`**: new SSDT for the FX507VV. The embedded controller is memory mapped
  (`OperationRegion IT55`, `0xFE700600`) under `\_SB.PC00.LPCB`. It exposes `\_SB.ATKD.RGSN` from
  `FA1L/H` (CPU fan, offset `0x02`), `FA2L/H` (GPU fan, `0x24`), `RCPU` (CPU temp, `0x04`) and
  `RVGA` (GPU temp, `0x0A`). This machine has no third fan, so fan 3 reads 0.
- **`RogControl/RogControl.cpp`**
  - `writeKbdLevel()` falls back to the ASUS WMI keyboard backlight (`0x00050021`, value
    `0x80 | level`) when no ASUS USB (N-KEY) keyboard is found. The TUF keyboard is not an
    `0b05` HID device on macOS.
  - New `TufRgb` property: 5 bytes `{mode, R, G, B, speed}` sent to WMI `0x00100056` as
    `B4-mode-R-G-B-speed`, what G-Helper sends. Modes: `0` static, `1` breathe, `2` colour cycle,
    `10` strobe. Speeds: `E1` slow, `EB` mid, `F5` fast.
  - Fn+F4 (ACPI code `0xB3`) cycles keyboard colour presets.
- **`tools/tufrgb.c`**: small command line tool that sets `TufRgb` on the kext.
- **`menubar/Model.swift`, `menubar/PanelView.swift`**: the panel runs `sudo -n /usr/local/bin/rogctl`
  and `sudo -n /usr/local/bin/tufrgb` directly instead of going through `rogd`, and drops the
  Strix-only Aura packets. It remembers the last colour.

## Keys on this laptop (ACPI codes seen by the kext)

| Key | Code | Action |
|---|---|---|
| Fn+F2 / Fn+F3 | `0xC5` / `0xC4` | Keyboard backlight down / up |
| Fn+F4 | `0xB3` | Cycle colour presets |
| Fn+F5 | `0xAE` | Next performance mode |
| Fn+F10 | `0x6B` | Touchpad toggle |
| Fn+F11 | `0xC0` | Sleep |

F7 / F8 brightness comes from the NVIDIA driver and `BrightnessKeys`, not from this kext.

## Requirements

- OpenCore with VirtualSMC and Lilu.
- Xcode or the Command Line Tools.
- The panel on dGPU (MUX) with an NVIDIA driver that registers `AppleBacklightDisplay`. With the
  nullmoth based driver this needs the boot-arg `nvrmacpibl=1`.

## Build

```sh
git clone --recursive https://github.com/<you>/<this-repo>.git
cd <this-repo>
./build.sh Release        # build/Release: RogControl.kext, rogd, rogctl, RogControl.app
```

If you downloaded a ZIP instead of cloning, `deps/` is empty (they are submodules) and the build
will fail. Clone with `--recursive`.

Compile the colour tool and the SSDT:

```sh
clang -o tufrgb tools/tufrgb.c -framework IOKit -framework CoreFoundation
iasl acpi/SSDT-ROG.dsl    # or open it in MaciASL; a prebuilt .aml is in acpi/
```

## Install

1. Copy `RogControl.kext` to `EFI/OC/Kexts` and list it in `Kernel > Add` after Lilu and VirtualSMC.
2. Copy `SSDT-ROG.aml` to `EFI/OC/ACPI` and list it in `ACPI > Add`.
3. Boot-args:
   ```
   -rogcontrolnocppc -rogcontrolnohid
   ```
   Optional, to apply settings at boot without `rogd`: `rogmode=0|1|2` (balanced, turbo, silent)
   and `rogcharge=80`.
4. Reboot and check:
   ```sh
   kextstat | grep -i rog
   ./build/Release/rogctl
   ```

**Do not run `tools/install.sh` or start `rogd` before reading its config.** The defaults are
fan curves and power limits for a Ryzen 9 7945HX.

### Keyboard colour and the menu bar app without `rogd`

```sh
sudo cp build/Release/rogctl tufrgb /usr/local/bin/
sudo chown root:wheel /usr/local/bin/rogctl /usr/local/bin/tufrgb
sudo chmod 755 /usr/local/bin/rogctl /usr/local/bin/tufrgb
sudo visudo -f /etc/sudoers.d/rogcontrol
```

Put one line in the sudoers file (your username in place of `me`):

```
me ALL=(root) NOPASSWD: /usr/local/bin/rogctl, /usr/local/bin/tufrgb
```

This lets your account run those two programs as root without a password. They are owned by
root, so an ordinary user cannot swap them, but `rogctl` takes many arguments; only do this on
a personal machine.

```sh
sudo tufrgb static ff0000
sudo tufrgb breathe 00ff00 fast
sudo tufrgb cycle slow
sudo tufrgb strobe
```

Copy `build/Release/RogControl.app` to `/Applications` and add it under
System Settings > General > Login Items.

## Boot-args

| Arg | Effect |
|---|---|
| `-rogcontrolnocppc` | Leave the CPU alone (needed on Intel) |
| `-rogcontrolnohid` | Turn off the N-KEY keyboard hook (the TUF keyboard is not one) |
| `rogmode=0\|1\|2` | Balanced, Turbo, Silent at boot |
| `rogcharge=N` | Charge limit at boot |
| `-rogcontroldbg` | Debug logging |
| `-rogcontroloff` | Disable the kext |

## Caveats

- Developed and tested on a single laptop. Other TUF models differ: the EC offsets in the SSDT,
  the WMI device IDs and the keyboard hardware may not match. Compare with your own DSDT.
- Be careful with fan settings. Watch temperatures (`rogctl watch`) when trying curves or fixed
  speeds.
- Nothing here was written by or checked with ASUS.

## Credits

- [pengubow/RogControl-macos](https://github.com/pengubow/RogControl-macos) for the original kext, `rogd`, `rogctl`
  and menu bar app.
- Linux `asus-wmi`, `asusctl` and G-Helper, for the WMI device IDs and behaviour this relies on.
- Acidanthera (Lilu, VirtualSMC).

## Contact
Any question?
Chat me on instagram [@nicholasgohansen](https://instagram.com/nicholasgohansen) or Discord `@nicholasgo`
