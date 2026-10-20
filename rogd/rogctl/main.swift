// rogctl: status and settings for RogControl (the macOS counterpart of asusctl).
// Settings go into /Library/Application Support/RogControl/config.json and rogd applies them.
import Foundation

let usage = """
usage: rogctl [status]                       fans, temperatures, profile, CPU/power limits
       rogctl watch                          status, refreshed every second
       rogctl profile [quiet|balanced|performance]
       rogctl auto on|off                    switch profile with the power source
       rogctl auto ac <profile> battery <profile>
       rogctl cpu max <MHz>|off              CPU frequency cap (all profiles)
       rogctl cpu epp <preference> [-p P]    performance|balance_performance|balance_power|power
       rogctl power [pl1 W] [pl2 W] [fppt W] [-p P] [--ac|--battery]   ('default' clears one)
       rogctl gpu [boost W] [temp C] [-p P] [--ac|--battery]
       rogctl tunings off [-p P] [--ac|--battery]    firmware power limits for that profile
       rogctl curve cpu|gpu T:P,T:P,... (8 points) [-p P]
       rogctl curve reset [-p P]             firmware fan curves for that profile
       rogctl charge <20-100>                battery charge limit
       rogctl kbd <0-3>                      keyboard backlight (also Fn+F2 / Fn+F3; 0 = off)
       rogctl touchpad on|off                (also Fn+F10)
       rogctl brightness <0-100>             screen brightness (also Fn+F7 / Fn+F8)
       rogctl events                         what the kext did since boot (restores, keyboard, backlight)
       rogctl aura                           keyboard lighting settings
       rogctl aura <mode> [rrggbb] [rrggbb]  static|breathe|rainbow_cycle|rainbow_wave|pulse (also the Aura key)
       rogctl aura speed low|med|high | direction right|left|up|down
       rogctl aura zones rrggbb rrggbb rrggbb rrggbb | zones off    four keyboard zones, left to right
       rogctl aura power keyboard|lightbar|all on|off [boot|awake|sleep|shutdown]
       rogctl fan <0-100>|auto               force both fans now (not saved)
       rogctl config                         show the config file

-p defaults to the active profile, --ac/--battery to the current power source.
Changing settings needs sudo.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
	FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
	exit(code)
}

guard let kext = RogKext() else { fail("RogControl.kext is not loaded") }

func num(_ props: [String: Any], _ key: String) -> Int? { (props[key] as? NSNumber)?.intValue }

func activeProfile() -> String {
	kext.mode.flatMap(profileName(forKextMode:)) ?? "balanced"
}

func eppName(_ v: Int) -> String {
	[0x00: "performance", 0x80: "balance_performance", 0xBF: "balance_power", 0xFF: "power"][v] ?? "custom"
}

func curveString(_ data: Data?) -> String? {
	guard let d = data, d.count == 16 else { return nil }
	return (0..<8).map { "\(d[$0])°C:\(d[$0 + 8])%" }.joined(separator: " ")
}

func showStatus() {
	let p = kext.properties()
	let config = (try? Config.load()) ?? Config()
	let mode = p["PerformanceMode"] as? String ?? "unknown"
	print("Profile          : \(profileName(forKextMode: mode) ?? mode) (\(mode))\(config.autoProfile?.enabled == true ? ", auto: AC \(config.autoProfile?.onAc ?? "-"), battery \(config.autoProfile?.onBattery ?? "-")" : "")")
	print("Power source     : \(onBatteryPower() ? "battery" : "AC")")
	print("Fan control      : \(p["FanControl"] as? String ?? "?")")
	print("CPU fan          : \(num(p, "CPU Fan RPM") ?? -1) RPM")
	print("GPU fan          : \(num(p, "GPU Fan RPM") ?? -1) RPM")
	print("CPU temperature  : \(num(p, "CPU Temperature") ?? -1) °C")
	print("GPU temperature  : \(num(p, "GPU Temperature") ?? -1) °C")
	let cppc = p["CPPC"] as? [String: Any] ?? [:]
	if p["CPUFrequencyLimitActive"] as? Bool == true {
		let cap = num(p, "CPUMaxFrequencyMHz") ?? 0
		print("CPU limit        : \(cap > 0 ? "\(cap) MHz" : "none"), EPP \(eppName(num(p, "CPUEnergyPreference") ?? -1)) (CPPC max_perf \(num(cppc, "MaxPerf") ?? 0)/\(num(cppc, "HighestPerf") ?? 0), \(num(cppc, "Cores") ?? 0) cores)")
	} else {
		print("CPU limit        : not set\((cppc["Supported"] as? Bool) == true ? "" : " (CPPC unsupported)")")
	}
	let tun = p["Tunables"] as? [String: Any] ?? [:]
	func t(_ key: String, _ label: String, _ unit: String) -> String? {
		guard let v = num(tun, key) else { return nil }
		return v == 0 ? "\(label) default" : "\(label) \(v)\(unit)"
	}
	let power = [t("PowerLimitPL1", "PL1", " W"), t("PowerLimitPL2", "PL2", " W"), t("PowerLimitFPPT", "FPPT", " W")].compactMap { $0 }
	let gpu = [t("GPUDynamicBoost", "dynamic boost", " W"), t("GPUTempTarget", "temp target", " °C")].compactMap { $0 }
	print("Power limits     : \(power.isEmpty ? "not supported" : power.joined(separator: ", "))")
	print("GPU (NVIDIA)     : \(gpu.isEmpty ? "not supported" : gpu.joined(separator: ", "))")
	if let charge = num(p, "ChargeLimit"), charge > 0 { print("Charge limit     : \(charge)%") }
	if let level = num(p, "ScreenBrightness"), let max = num(p, "ScreenBrightnessMax") {
		print("Screen brightness: \(level * 100 / Swift.max(max, 1))% (EC)")
	} else if let value = panelBrightness() {
		print("Screen brightness: \(Int((value * 100).rounded()))% (NVIDIA driver\(p["BrightnessKeys"] as? Bool == true ? "" : ", Fn+F7/F8 unavailable"))")
	} else if num(p, "ScreenBrightnessSource") == 1 {
		print("Screen brightness: no control (the NVIDIA driver registered no backlight; needs boot-arg nvrmacpibl=1)")
	}
	if let touchpad = p["TouchpadEnabled"] as? Bool { print("Touchpad         : \(touchpad ? "on" : "off")") }
	let found = p["KeyboardFound"] as? Bool == true ? "" : " (keyboard not found yet)"
	if let level = num(p, "KeyboardBrightness") {
		print("Keyboard light   : \(level)/3\(found)")
	} else if p["KeyboardFound"] != nil {
		print("Keyboard light   : not set yet (firmware's)\(found)")
	}
	if let count = num(p, "HotkeyCount") {
		let hook = p["KeyboardHotkeyHook"] as? Bool == true ? "keyboard hook on" : "keyboard hook OFF"
		print("Fn keys          : \(hook), \(count) pressed\(count > 0 ? ", last 0x" + String(num(p, "LastHotkey") ?? 0, radix: 16, uppercase: true) : "")")
	}
	if let c = curveString(p["AppliedCurveCPU"] as? Data) { print("  CPU curve: \(c)") }
	if let c = curveString(p["AppliedCurveGPU"] as? Data) { print("  GPU curve: \(c)") }
}

/// Saves the config and has rogd apply it; without rogd, applies it here.
func commit(_ config: Config) {
	do { try config.save() } catch { fail("cannot write \(configPath) (\(error.localizedDescription)); run with sudo") }
	if let pidText = try? String(contentsOfFile: pidPath, encoding: .utf8),
		let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, SIGHUP) == 0 {
		usleep(600_000)
	} else {
		let name = activeProfile()
		let ret = kext.set(profileRequest(config, profile: name, onBattery: onBatteryPower(), includeMode: false))
		if ret == kIOReturnNotPrivileged { fail("permission denied, run with sudo") }
		print("(rogd is not running: applied \(name) directly)")
	}
	showStatus()
}

/// Splits "-p P", "--ac", "--battery" off the arguments.
func options(_ args: [String]) -> (rest: [String], profile: String, battery: Bool) {
	var rest: [String] = [], profile = activeProfile(), battery = onBatteryPower()
	var i = 0
	while i < args.count {
		switch args[i] {
		case "-p", "--profile":
			guard i + 1 < args.count, profileNames.contains(args[i + 1]) else { fail("profile must be one of \(profileNames.joined(separator: ", "))") }
			profile = args[i + 1]; i += 1
		case "--ac": battery = false
		case "--battery": battery = true
		default: rest.append(args[i])
		}
		i += 1
	}
	return (rest, profile, battery)
}

func editTuning(_ args: [String], keys: [String: WritableKeyPath<Tuning, Int?>]) {
	let (rest, name, battery) = options(args)
	guard !rest.isEmpty, rest.count % 2 == 0 else { fail(usage, code: 2) }
	var config = (try? Config.load()) ?? Config()
	var profile = config.profiles[name] ?? Profile()
	var tunings = profile.tunings ?? Tunings()
	var tuning = (battery ? tunings.battery : tunings.ac) ?? Tuning()
	for i in stride(from: 0, to: rest.count, by: 2) {
		guard let path = keys[rest[i]] else { fail(usage, code: 2) }
		if rest[i + 1] == "default" {
			tuning[keyPath: path] = nil
		} else {
			guard let v = Int(rest[i + 1]), v > 0 else { fail("\(rest[i]) needs a number") }
			tuning[keyPath: path] = v
		}
	}
	tuning.enabled = true
	if battery { tunings.battery = tuning } else { tunings.ac = tuning }
	profile.tunings = tunings
	config.profiles[name] = profile
	commit(config)
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"
if !args.isEmpty { args.removeFirst() }

switch command {
case "status":
	showStatus()
case "watch":
	while true {
		print("\u{1B}[H\u{1B}[2J", terminator: "")
		showStatus()
		fflush(stdout)
		sleep(1)
	}
case "profile":
	if let name = args.first {
		guard let mode = kextMode(forProfile: name) else { fail("profile must be one of \(profileNames.joined(separator: ", "))") }
		if kext.set(["PerformanceMode": mode]) == kIOReturnNotPrivileged { fail("permission denied, run with sudo") }
		usleep(2_500_000)   // rogd notices the mode change and applies the rest of the profile
	}
	showStatus()
case "auto":
	var config = (try? Config.load()) ?? Config()
	var auto = config.autoProfile ?? AutoProfile(enabled: false, onAc: "balanced", onBattery: "quiet")
	if args == ["on"] || args == ["off"] {
		auto.enabled = args[0] == "on"
	} else if args.count == 4, args[0] == "ac", args[2] == "battery",
		profileNames.contains(args[1]), profileNames.contains(args[3]) {
		auto = AutoProfile(enabled: true, onAc: args[1], onBattery: args[3])
	} else {
		fail(usage, code: 2)
	}
	config.autoProfile = auto
	commit(config)
case "cpu":
	var config = (try? Config.load()) ?? Config()
	if args.count == 2 && args[0] == "max" {
		if args[1] == "off" {
			config.cpuMaxMhz = 0
		} else {
			guard let mhz = Int(args[1]), (400...6500).contains(mhz) else { fail("cpu max needs MHz (400-6500) or off") }
			config.cpuMaxMhz = mhz
		}
	} else if args.count >= 2 && args[0] == "epp" {
		let (rest, name, _) = options(Array(args.dropFirst()))
		let names = ["performance", "balance_performance", "balance_power", "power"]
		guard rest.count == 1, names.contains(rest[0]) else { fail("epp must be one of \(names.joined(separator: ", "))") }
		var profile = config.profiles[name] ?? Profile()
		profile.epp = rest[0]
		config.profiles[name] = profile
	} else {
		fail(usage, code: 2)
	}
	commit(config)
case "power":
	editTuning(args, keys: ["pl1": \.pl1, "pl2": \.pl2, "fppt": \.fppt])
case "gpu":
	editTuning(args, keys: ["boost": \.gpuDynamicBoost, "temp": \.gpuTempTarget])
case "tunings":
	let (rest, name, battery) = options(args)
	guard rest == ["off"] else { fail(usage, code: 2) }
	var config = (try? Config.load()) ?? Config()
	var profile = config.profiles[name] ?? Profile()
	var tunings = profile.tunings ?? Tunings()
	if battery { tunings.battery?.enabled = false } else { tunings.ac?.enabled = false }
	profile.tunings = tunings
	config.profiles[name] = profile
	commit(config)
case "curve":
	let (rest, name, _) = options(args)
	var config = (try? Config.load()) ?? Config()
	var profile = config.profiles[name] ?? Profile()
	var curves = profile.fanCurves ?? FanCurves()
	if rest == ["reset"] {
		curves.enabled = false
	} else if rest.count == 2, rest[0] == "cpu" || rest[0] == "gpu" {
		let points = rest[1].split(separator: ",").map { $0.split(separator: ":").compactMap { Int($0) } }
		guard curveData(points) != nil else {
			fail("curve needs 8 ascending points like 40:10,50:20,60:30,70:45,75:55,80:70,90:90,100:100")
		}
		if rest[0] == "cpu" { curves.cpu = points } else { curves.gpu = points }
		// The kext writes both fans at once: start the other one from the firmware's current curve.
		let other = rest[0] == "cpu" ? "AppliedCurveGPU" : "AppliedCurveCPU"
		if (rest[0] == "cpu" ? curves.gpu : curves.cpu) == nil, let d = kext.properties()[other] as? Data, d.count == 16 {
			let pts = (0..<8).map { [Int(d[$0]), Int(d[$0 + 8])] }
			if rest[0] == "cpu" { curves.gpu = pts } else { curves.cpu = pts }
		}
		curves.enabled = curves.cpu != nil && curves.gpu != nil
		if !curves.enabled { print("note: set the other fan's curve too; until then the firmware curves stay") }
	} else {
		fail(usage, code: 2)
	}
	profile.fanCurves = curves
	config.profiles[name] = profile
	commit(config)
case "charge":
	guard args.count == 1, let v = Int(args[0]), (20...100).contains(v) else { fail(usage, code: 2) }
	var config = (try? Config.load()) ?? Config()
	config.chargeLimit = v
	commit(config)
case "kbd":
	guard args.count == 1, let level = Int(args[0]), (0...3).contains(level) else { fail("kbd needs a level 0-3") }
	let ret = kext.set(["KeyboardBrightness": level])
	if ret == kIOReturnNotPrivileged { fail("permission denied, run with sudo") }
	if ret != KERN_SUCCESS { fail(String(format: "the keyboard did not take it (0x%x)", ret)) }
	showStatus()
case "brightness":
	guard args.count == 1, let pct = Int(args[0]), (0...100).contains(pct) else { fail("brightness needs 0-100") }
	let props = kext.properties()
	if num(props, "ScreenBrightness") != nil, let max = num(props, "ScreenBrightnessMax"), max > 0 {
		let ret = kext.set(["ScreenBrightness": pct * max / 100])
		if ret == kIOReturnNotPrivileged { fail("permission denied, run with sudo") }
		if ret != KERN_SUCCESS { fail(String(format: "the backlight did not take it (0x%x)", ret)) }
	} else if panelBrightness() != nil {
		guard setPanelBrightness(Float(pct) / 100) else { fail("macOS refused the brightness change") }
	} else {
		fail("no screen backlight control (the NVIDIA driver registered no backlight; needs boot-arg nvrmacpibl=1)")
	}
	showStatus()
case "aura":
	var config = (try? Config.load()) ?? Config()
	var aura = config.aura ?? Aura()
	func show(_ a: Aura) {
		let p = a.power ?? AuraPower()
		func states(_ s: AuraPowerState) -> String {
			let on = [("boot", s.boot), ("awake", s.awake), ("sleep", s.sleep), ("shutdown", s.shutdown)].filter { $0.1 }.map { $0.0 }
			return on.isEmpty ? "off" : on.joined(separator: ", ")
		}
		print("Mode       : \(a.mode ?? "(not set: the keyboard keeps its own)")")
		if let zones = a.zones { print("Zones      : \(zones.joined(separator: " "))") } else { print("Colour     : \(a.colour ?? "ffffff")\(a.colour2.map { ", second \($0)" } ?? "")") }
		print("Speed      : \(a.speed ?? "med"), direction \(a.direction ?? "right")")
		print("Brightness : \(a.brightness ?? "-") (default keyboard light; Fn+F2/F3 change it)")
		print("Keyboard   : \(states(p.keyboard))")
		print("Lightbar   : \(states(p.lightbar))")
	}
	if args.isEmpty { show(aura); exit(0) }
	switch args[0] {
	case "speed":
		guard args.count == 2, auraSpeeds[args[1]] != nil else { fail("speed is low, med or high") }
		aura.speed = args[1]
	case "direction":
		guard args.count == 2, auraDirections[args[1]] != nil else { fail("direction is right, left, up or down") }
		aura.direction = args[1]
	case "zones":
		if args == ["zones", "off"] {
			aura.zones = nil
		} else {
			guard args.count == 5, args[1...].allSatisfy({ rgb($0) != nil }) else { fail("zones needs 4 colours rrggbb") }
			aura.zones = Array(args[1...])
		}
	case "power":
		guard args.count >= 3, ["keyboard", "lightbar", "all"].contains(args[1]), ["on", "off"].contains(args[2]) else { fail(usage, code: 2) }
		let on = args[2] == "on"
		let which = args.count > 3 ? Array(args[3...]) : ["boot", "awake", "sleep", "shutdown"]
		guard which.allSatisfy({ ["boot", "awake", "sleep", "shutdown"].contains($0) }) else { fail("states are boot, awake, sleep, shutdown") }
		var power = aura.power ?? AuraPower()
		func update(_ s: inout AuraPowerState) {
			for w in which {
				switch w {
				case "boot": s.boot = on
				case "awake": s.awake = on
				case "sleep": s.sleep = on
				default: s.shutdown = on
				}
			}
		}
		if args[1] != "lightbar" { update(&power.keyboard) }
		if args[1] != "keyboard" { update(&power.lightbar) }
		aura.power = power
	default:
		guard auraModes[args[0]] != nil, args.count <= 3 else { fail("unknown aura mode \(args[0]); modes: \(auraCycle.joined(separator: ", "))") }
		aura.mode = args[0]
		if args.count > 1 { guard rgb(args[1]) != nil else { fail("colour must be rrggbb") }; aura.colour = args[1].lowercased() }
		if args.count > 2 { guard rgb(args[2]) != nil else { fail("colour must be rrggbb") }; aura.colour2 = args[2].lowercased() }
	}
	guard aura.problems.isEmpty else { fail(aura.problems.joined(separator: "; ")) }
	config.aura = aura
	do { try config.save() } catch { fail("cannot write \(configPath) (\(error.localizedDescription)); run with sudo") }
	if let pidText = try? String(contentsOfFile: pidPath, encoding: .utf8),
		let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, SIGHUP) == 0 {
		usleep(600_000)
	} else {
		let ret = kext.set(["AuraReports": aura.packets()])
		if ret == kIOReturnNotPrivileged { fail("permission denied, run with sudo") }
		print("(rogd is not running: sent directly)")
	}
	show(aura)
case "events":
	for line in kext.properties()["EventLog"] as? [String] ?? [] { print(line) }
case "touchpad":
	guard args == ["on"] || args == ["off"] else { fail("touchpad needs on or off") }
	let ret = kext.set(["TouchpadEnabled": args[0] == "on"])
	if ret == kIOReturnNotPrivileged { fail("permission denied, run with sudo") }
	if ret != KERN_SUCCESS { fail(String(format: "no touchpad driver answered (0x%x)", ret)) }
	showStatus()
case "fan":
	guard args.count == 1 else { fail(usage, code: 2) }
	let pct = args[0] == "auto" ? -1 : (Int(args[0]) ?? -2)
	guard pct >= -1 && pct <= 100 else { fail(usage, code: 2) }
	if kext.set(["FanSpeedPercent": pct]) == kIOReturnNotPrivileged { fail("permission denied, run with sudo") }
	showStatus()
case "config":
	print(configPath)
	print((try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "(none yet: stock firmware behaviour)")
case "-h", "--help", "help":
	print(usage)
default:
	fail(usage, code: 2)
}
