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
