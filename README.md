# RogControl for macOS

Fan, temperature and performance control for ASUS ROG laptops on macOS (OpenCore),
built for the ROG Strix G17 G713PV (Ryzen 9 7945HX, RTX 4060 Laptop). The goal is
what `asusctl` / ROG Control Center do on Linux.

`RogControl.kext` is a VirtualSMC plugin. It talks to the firmware through the
same ASUS WMI calls Linux `asus-wmi` makes (`\_SB.ATKD.WMNB`):

- fan RPM and EC CPU/GPU temperatures as SMC keys (monitoring apps, Macs Fan Control)
- performance modes Silent / Balanced / Turbo, also on Fn+F5
- custom fan curves (8 points per fan) and fixed fan speeds
- battery charge limit

Planned: CPU frequency cap and power limits, saved profiles, Fn keys, keyboard
backlight and Aura lighting (background service + `rogctl`), menu-bar app.

## Requirements

- VirtualSMC and Lilu
- `acpi/SSDT-ROG.aml`: adds `\_SB.ATKD.RGSN` (fan RPM + EC temperatures) for the
  G713PV's embedded controller fields

## Build

```sh
git submodule update --init
./build.sh Release        # build/Release/RogControl.kext and rogctl
```

macOS: Xcode or the Command Line Tools. Linux: cross build with Apple clang/ld64,
see the variables at the top of `build.sh`.

## rogctl

```sh
rogctl                              # fans, temperatures, mode, charge limit, curves
rogctl watch
sudo rogctl mode silent|balanced|turbo
sudo rogctl charge 80
sudo rogctl fan 60 | auto
sudo rogctl curve cpu 40:10,50:20,60:30,70:45,75:55,80:70,90:90,100:100
sudo rogctl curve reset
```

Mode and charge limit persist in NVRAM; boot-args `rogmode=0|1|2` (balanced,
turbo, silent) and `rogcharge=N` override them. Custom curves never drop below
80% at 90 °C (`-rogcontrolnosafety` disables that). `-rogcontroloff` disables
the kext, `-rogcontroldbg` enables debug logging.
