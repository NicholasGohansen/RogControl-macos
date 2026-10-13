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
- CPU frequency cap through AMD CPPC, like Linux `amd-pstate` /
  `cpupower frequency-set -u` with an energy preference (EPP)
- package power limits PL1/PL2/FPPT and NVIDIA dynamic boost / temperature target
  (the asusd "tunings")

- the N-KEY keyboard's Fn keys, read from its vendor input report (0x5A) through a Lilu hook on
  `IOHIDDevice::handleReportWithTime`, which also works while Karabiner-Elements holds the
  keyboard: Fn+F2/F3 keyboard light, Fn+F5 mode, Fn+F7/F8 screen brightness, Fn+F10 touchpad
  (VoodooI2C); the mic-mute key is handled by `rogd`
- keyboard backlight (HID feature report, like Linux `hid-asus`)
- screen brightness: with the MUX in dGPU mode the NVIDIA driver drives the panel, so Fn+F7/F8
  are sent to macOS as brightness keys (needs the nullmoth NVIDIA driver with boot-arg
  `nvrmacpibl=1`, which lets it read the panel's backlight table from ACPI and register the
  panel as `AppleBacklightDisplay`); in hybrid mode the EC backlight (NVIDIA WMI method) is used

- profiles applied by `rogd`, edited with `rogctl` (below)

Planned: Aura lighting, menu-bar app.

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

## rogd and rogctl

The kext does nothing on its own beyond the firmware's stock behaviour. Settings live in
`/Library/Application Support/RogControl/config.json`, and `rogd` (a LaunchDaemon, the
counterpart of asusd) applies them:

- one profile per performance mode: `quiet` (ASUS Silent), `balanced`, `performance` (Turbo),
  each with fan curves, a CPU energy preference (EPP) and power "tunings" for AC and battery
- at start (the last profile used), when the mode changes (Fn+F5 or `rogctl profile`), and on
  AC <-> battery, optionally switching profile with the power source (`auto_profile`)
- global CPU frequency cap and battery charge limit

```sh
./build.sh Release && sudo tools/install.sh [config.json]

rogctl                              # fans, temperatures, profile, CPU/power limits, curves
rogctl watch
sudo rogctl profile quiet|balanced|performance
sudo rogctl auto ac balanced battery quiet   # or: auto on|off
sudo rogctl cpu max 4200 | off
sudo rogctl cpu epp power -p quiet
sudo rogctl power pl1 70 pl2 95 fppt 100     # active profile, current power source
sudo rogctl gpu boost 5 temp 75 -p balanced --ac
sudo rogctl curve cpu 40:10,50:20,60:30,70:45,75:55,80:70,90:90,100:100
sudo rogctl curve reset -p performance
sudo rogctl charge 80
sudo rogctl fan 60 | auto                    # temporary, not saved
sudo rogctl kbd 0..3                         # keyboard light (also Fn+F2/F3)
sudo rogctl touchpad on|off                  # also Fn+F10
sudo rogctl brightness 0..100                # also Fn+F7/F8
sudo rogctl brightness keys topcase|consumer # what Fn+F7/F8 send to macOS
rogctl events                                # what the kext did since boot
rogctl config
```

### Coming from Linux asusctl

`tools/import-asusd.py DIR > config.json` converts copies of `/etc/asusd/asusd.ron`,
`fan_curves.ron`, `aura_*.ron` and any systemd units running `cpupower frequency-set -u` or
`nvidia-smi -lgc` into a config: fan curves (pwm to percent like asus-wmi), linked EPP,
AC/DC tunings, profile switching on AC/battery, charge limit, CPU cap. GPU clock locks,
panel overdrive and Aura are kept in the config but not applied yet.

## Boot-args

Mode, charge limit and keyboard light also persist in NVRAM. `rogmode=0|1|2` (balanced, turbo, silent),
`rogcharge=N`, `rogcpumax=MHz` (0 = no cap) and `rogepp=0..255` work without rogd.
`-rogcontrolnocppc` leaves the CPU alone. Custom curves never drop below 80% at 90 °C
(`-rogcontrolnosafety` disables that). `-rogcontroloff` disables the kext,
`-rogcontroldbg` enables debug logging, `-rogcontrolnohid` turns off the keyboard hook.
