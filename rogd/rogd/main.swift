// rogd: applies RogControl profiles (the macOS counterpart of asusd).
//   - at start, the last profile used and the keyboard light (kept in state.json)
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

/// RogControl.kext sends every ASUS hotkey (ATK event or keyboard report 0x5A) as
/// iokit_vendor_specific_msg(0x52), code in the argument.
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
	var state = State.load()
	var appliedAura: Aura?
	var kext: RogKext?
	var lastMode: String?
	/// A profile whose mode the kext refused (early in boot); retried, and not mistaken for a
	/// mode change in the meantime.
	var pendingProfile: String?
	var pendingTries = 0
	var lastOnBattery = onBatteryPower()
	var notifyPort: IONotificationPortRef?
	var hotkeyNotification: io_object_t = 0

	/// Hotkeys the kext doesn't handle itself (it does Fn+F5, Fn+F2/F3, Fn+F7/F8 and Fn+F10).
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
			cycleAura()
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
		lastOnBattery = battery
		if setMode && ret != KERN_SUCCESS && kextMode(forProfile: name) != kext.mode {
			pendingProfile = pendingTries < 30 ? name : nil
			pendingTries += 1
			lastMode = kext.mode
			log("\(name): the kext did not take the mode yet (0x\(String(ret, radix: 16))), \(pendingProfile == nil ? "giving up" : "retrying")")
			return
		}
		pendingProfile = nil
		lastMode = kextMode(forProfile: name)
		state.profile = name
		saveState()
		log("applied \(name) (\(reason), \(battery ? "battery" : "AC"))\(ret == KERN_SUCCESS ? "" : String(format: ", kext rejected a value (0x%x)", ret))")
	}

	/// The profile of the current mode: the kext restores the last mode from NVRAM at boot,
	/// so this is whatever was used last (Fn+F5, rogctl profile, or an auto switch).
	func currentProfile() -> String {
		kext?.mode.flatMap(profileName(forKextMode:)) ?? "balanced"
	}

	/// The auto profile for the power source, if switching on AC/battery is enabled.
	func autoProfile() -> String? {
		guard let auto = config.autoProfile, auto.enabled,
			let target = onBatteryPower() ? auto.onBattery : auto.onAc, profileNames.contains(target) else { return nil }
		return target
	}

	func applyCurrent(reason: String) {
		apply(profile: currentProfile(), setMode: false, reason: reason)
	}

	func poll() {
		if kext == nil {
			kext = RogKext()
			if kext != nil {
				log("RogControl.kext found")
				listenForHotkeys()
				restoreState()
				applyAura(reason: "start")
				if let saved = state.profile, profileNames.contains(saved), kextMode(forProfile: saved) != kext?.mode {
					apply(profile: saved, setMode: true, reason: "start, last used")
				} else {
					applyCurrent(reason: "start")
				}
			}
			return
		}
		guard let mode = kext?.mode else { return }
		if let pending = pendingProfile {
			apply(profile: pending, setMode: true, reason: "start, last used (retry)")
			return
		}
		recordState()
		if mode != lastMode, let name = profileName(forKextMode: mode) {
			apply(profile: name, setMode: false, reason: "mode changed to \(mode)")
		}
	}

	/// Sends the Aura settings when they differ from what was last sent (APPLY writes the
	/// keyboard's own storage, so not on every config reload).
	func applyAura(reason: String) {
		guard let kext = kext, let aura = config.aura, aura.mode != nil || aura.zones != nil, aura != appliedAura else { return }
		guard aura.problems.isEmpty else {
			log("aura not applied: \(aura.problems.joined(separator: ", "))")
			return
		}
		let ret = kext.set(["AuraReports": aura.packets()])
		appliedAura = aura
		let what = aura.zones != nil ? "zones \(aura.zones!.joined(separator: " "))" : (aura.colour ?? "")
		log("aura \(aura.mode ?? "static") \(what) (\(reason))\(ret == KERN_SUCCESS ? "" : String(format: ", kext: 0x%x", ret))")
	}

	/// The Aura key: next mode, like asusd.
	func cycleAura() {
		var aura = config.aura ?? Aura()
		let current = auraCycle.firstIndex(of: aura.mode ?? "static") ?? -1
		aura.mode = auraCycle[(current + 1) % auraCycle.count]
		config.aura = aura
		do { try config.save() } catch { log("could not save the Aura mode: \(error)") }
		applyAura(reason: "Aura key")
	}

	func saveState() {
		do { try state.save() } catch { log("could not save \(statePath): \(error)") }
	}

	/// Puts back what the user last chose that isn't part of a profile (the keyboard light comes
	/// up dark and the kext waits for its driver before writing it).
	func restoreState() {
		guard let kext = kext else { return }
		var req: [String: Any] = [:]
		if let level = state.keyboardLight ?? config.aura?.brightness.flatMap({ auraBrightness[$0] }), (0...3).contains(level) {
			req["KeyboardBrightness"] = level
		}
		if let level = state.screenBrightness, kext.properties()["ScreenBrightness"] != nil { req["ScreenBrightness"] = level }
		guard !req.isEmpty else { return }
		let ret = kext.set(req)
		log("restored \(req.keys.sorted().joined(separator: ", "))\(ret == KERN_SUCCESS ? "" : String(format: " (kext: 0x%x)", ret))")
	}

	/// Remembers changes made with the keys (Fn+F2/F3, Fn+F7/F8) or rogctl.
	func recordState() {
		guard let props = kext?.properties() else { return }
		var next = state
		if let level = props["KeyboardBrightness"] as? Int { next.keyboardLight = level }
		if let level = props["ScreenBrightness"] as? Int { next.screenBrightness = level }
		if next != state {
			state = next
			saveState()
		}
	}

	func powerChanged() {
		let battery = onBatteryPower()
		guard battery != lastOnBattery else { return }
		if let target = autoProfile() {
			apply(profile: target, setMode: kextMode(forProfile: target) != kext?.mode, reason: "power source changed")
		} else {
			applyCurrent(reason: "power source changed")
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
	daemon.applyAura(reason: "config reloaded")
}
hup.resume()

let powerSource = IOPSNotificationCreateRunLoopSource({ _ in daemon.powerChanged() }, nil).takeRetainedValue()
CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode)

let timer = Timer(timeInterval: 2, repeats: true) { _ in daemon.poll() }
RunLoop.main.add(timer, forMode: .default)
daemon.poll()
RunLoop.main.run()
