// rogd: applies RogControl profiles (the macOS counterpart of asusd).
//   - at start, the profile for the current power source (auto profile) or the current mode
//   - when the performance mode changes (Fn+F5, rogctl profile): that profile's curves, EPP, tunings
//   - on AC <-> battery: the configured profile, or the other set of tunings
//   - SIGHUP (sent by rogctl after editing the config): reload and apply again
// Runs as root from /Library/LaunchDaemons/com.pengubow.rogd.plist.
import CoreAudio
import Foundation
import IOKit.ps

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ message: String) {
	print("\(timestamp()) \(message)")
}

/// RogControl.kext sends every ASUS ATK hotkey as iokit_vendor_specific_msg(0x52), code in the argument.
let hotkeyMessage: UInt32 = 0xE000_0000 | (0xFFE << 14) | 0x52

enum Hotkey: UInt32 {
	case micMute = 0x7C
	case rogKey = 0x38
	case auraKey = 0xB3
}

/// Mutes or unmutes the default input device (the keyboard's mic-mute key).
func toggleMicMute() -> String {
	var device = AudioObjectID(kAudioObjectUnknown)
	var size = UInt32(MemoryLayout<AudioObjectID>.size)
	var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
		mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
	guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
		device != kAudioObjectUnknown else { return "no input device" }
	address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
		mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
	var muted: UInt32 = 0
	size = UInt32(MemoryLayout<UInt32>.size)
	guard AudioObjectHasProperty(device, &address),
		AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else {
		return "input device has no mute control"
	}
	muted = muted == 0 ? 1 : 0
	let ret = AudioObjectSetPropertyData(device, &address, 0, nil, size, &muted)
	return ret == noErr ? (muted == 1 ? "microphone muted" : "microphone unmuted") : "mute failed (\(ret))"
}

final class Daemon {
	var config = Config()
	var kext: RogKext?
	var lastMode: String?
	var lastOnBattery = onBatteryPower()
	var notifyPort: IONotificationPortRef?
	var hotkeyNotification: io_object_t = 0

	/// Hotkeys the kext doesn't handle itself (it does Fn+F5, Fn+F2/F3 and Fn+F10).
	func listenForHotkeys() {
		guard let kext = kext, hotkeyNotification == 0 else { return }
		notifyPort = IONotificationPortCreate(kIOMainPortDefault)
		guard let port = notifyPort else { return }
		CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
		let ret = IOServiceAddInterestNotification(port, kext.service, kIOGeneralInterest, { _, _, type, argument in
			guard type == hotkeyMessage else { return }
			daemon.hotkey(UInt32(UInt(bitPattern: argument)))
		}, nil, &hotkeyNotification)
		if ret != KERN_SUCCESS { log(String(format: "hotkey notifications unavailable (0x%x)", ret)) }
	}

	func hotkey(_ code: UInt32) {
		switch Hotkey(rawValue: code) {
		case .micMute:
			log("mic-mute key: \(toggleMicMute())")
		case .rogKey:
			log("ROG key pressed (not assigned yet)")
		case .auraKey:
			log("Aura key pressed (not assigned yet)")
		case nil:
			break
		}
	}

	func loadConfig() {
		do {
			config = try Config.load()
			log("config loaded: cpu cap \(config.cpuMaxMhz ?? 0) MHz, auto profile \(config.autoProfile?.enabled == true), profiles \(config.profiles.keys.sorted())")
		} catch {
			log("config error, keeping the previous settings: \(error)")
		}
	}

	/// Drop what this machine's firmware doesn't offer, so one unsupported value
	/// doesn't make the kext reject the request.
	func filtered(_ req: [String: Any], _ props: [String: Any]) -> [String: Any] {
		var out = req
		let supported = (props["Tunables"] as? [String: Any]).map { Set($0.keys) } ?? []
		for (_, key) in tunableKeys where !supported.contains(key) {
			out.removeValue(forKey: key)
		}
		if (props["CPPC"] as? [String: Any])?["Supported"] as? Bool != true {
			out.removeValue(forKey: "CPUMaxFrequencyMHz")
			out.removeValue(forKey: "CPUEnergyPreference")
		}
		return out
	}

	func apply(profile name: String, setMode: Bool, reason: String) {
		guard let kext = kext else { return }
		let battery = onBatteryPower()
		let req = filtered(profileRequest(config, profile: name, onBattery: battery, includeMode: setMode), kext.properties())
		let ret = kext.set(req)
		lastMode = kextMode(forProfile: name)
		lastOnBattery = battery
		log("applied \(name) (\(reason), \(battery ? "battery" : "AC"))\(ret == KERN_SUCCESS ? "" : String(format: ", kext rejected a value (0x%x)", ret))")
	}

	/// The profile to use now: the auto profile for the power source, else the current mode.
	func currentProfile() -> String {
		if let auto = config.autoProfile, auto.enabled,
			let target = onBatteryPower() ? auto.onBattery : auto.onAc, profileNames.contains(target) {
			return target
		}
		return kext?.mode.flatMap(profileName(forKextMode:)) ?? "balanced"
	}

	func applyCurrent(reason: String) {
		let name = currentProfile()
		apply(profile: name, setMode: kextMode(forProfile: name) != kext?.mode, reason: reason)
	}

	func poll() {
		if kext == nil {
			kext = RogKext()
			if kext != nil {
				log("RogControl.kext found")
				listenForHotkeys()
				applyCurrent(reason: "start")
			}
			return
		}
		guard let mode = kext?.mode else { return }
		if mode != lastMode, let name = profileName(forKextMode: mode) {
			apply(profile: name, setMode: false, reason: "mode changed to \(mode)")
		}
	}

	func powerChanged() {
		let battery = onBatteryPower()
		guard battery != lastOnBattery else { return }
		if config.autoProfile?.enabled == true {
			applyCurrent(reason: "power source changed")
		} else if let mode = kext?.mode, let name = profileName(forKextMode: mode) {
			apply(profile: name, setMode: false, reason: "power source changed")
		}
	}
}

let daemon = Daemon()
daemon.loadConfig()
try? "\(getpid())\n".write(toFile: pidPath, atomically: true, encoding: .utf8)
log("rogd started")

signal(SIGHUP, SIG_IGN)
let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
hup.setEventHandler {
	daemon.loadConfig()
	daemon.applyCurrent(reason: "config reloaded")
}
hup.resume()

let powerSource = IOPSNotificationCreateRunLoopSource({ _ in daemon.powerChanged() }, nil).takeRetainedValue()
CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode)

let timer = Timer(timeInterval: 2, repeats: true) { _ in daemon.poll() }
RunLoop.main.add(timer, forMode: .default)
daemon.poll()
RunLoop.main.run()
