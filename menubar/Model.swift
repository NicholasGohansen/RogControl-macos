// What the panel shows, read from the kext and the config; changes go through rogd.
import Combine
import Foundation
import IOKit

private func number(_ props: [String: Any], _ key: String) -> Int? { (props[key] as? NSNumber)?.intValue }

private let eppNames: [Int: String] = [0x00: "performance", 0x80: "balance performance", 0xBF: "balance power", 0xFF: "power"]

final class StatusModel: ObservableObject {
	@Published var available = false
	@Published var cpuTemp: Int?
	@Published var gpuTemp: Int?
	@Published var cpuFan: Int?
	@Published var gpuFan: Int?
	@Published var profile = "balanced"
	@Published var autoProfile = false
	@Published var autoText = ""
	@Published var onBattery = false
	@Published var keyboardLight: Int?
	@Published var keyboardFound = false
	@Published var touchpad = true
	@Published var brightness: Double?
	@Published var cpuLimit = ""
	@Published var powerLimits = ""
	@Published var chargeLimit: Int?
	@Published var aura = Aura()
	@Published var error: String?

	let client = RogdClient()
	private var kext: RogKext?
	private var timer: Timer?
	private var heldUntil = Date.distantPast    // the user just changed something: don't overwrite it
	private var auraSend: DispatchWorkItem?
	var panelOpen = false

	// The panel brightness doesn't survive a restart here (macOS keeps it in NVRAM, which OpenCore
	// doesn't let it write), and rogd can't reach the display: the app puts back the level rogd
	// kept, then reports changes (keys, Control Center, the slider) for rogd to keep.
	private let savedBrightness = State.load().panelBrightness.map { Float($0) }
	private var brightnessFound = false
	private var keptBrightness: Float?

	init() {
		refresh()
		timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
	}

	func refresh() {
		if kext == nil { kext = RogKext() }
		guard let kext = kext else { available = false; return }
		let p = kext.properties()
		available = !p.isEmpty
		cpuTemp = number(p, "CPU Temperature")
		gpuTemp = number(p, "GPU Temperature")
		cpuFan = number(p, "CPU Fan RPM")
		gpuFan = number(p, "GPU Fan RPM")
		onBattery = onBatteryPower()
		keepBrightness()
		// The rest is only shown in the panel, and not while the user's own change settles.
		guard panelOpen, Date() > heldUntil else { return }
		if let mode = p["PerformanceMode"] as? String, let name = profileName(forKextMode: mode) { profile = name }
		keyboardLight = number(p, "KeyboardBrightness")
		keyboardFound = p["KeyboardFound"] as? Bool ?? false
		touchpad = p["TouchpadEnabled"] as? Bool ?? true
		chargeLimit = number(p, "ChargeLimit").flatMap { $0 > 0 ? $0 : nil }
		if p["CPUFrequencyLimitActive"] as? Bool == true {
			let cap = number(p, "CPUMaxFrequencyMHz") ?? 0
			let epp = eppNames[number(p, "CPUEnergyPreference") ?? -1] ?? "custom"
			cpuLimit = "CPU \(cap > 0 ? "max \(cap) MHz" : "no cap"), \(epp)"
		} else {
			cpuLimit = "CPU stock"
		}
		let tun = p["Tunables"] as? [String: Any] ?? [:]
		let parts = [("PowerLimitPL1", "PL1"), ("PowerLimitPL2", "PL2"), ("PowerLimitFPPT", "FPPT")].compactMap { key, label -> String? in
			guard let v = number(tun, key) else { return nil }
			return v == 0 ? nil : "\(label) \(v) W"
		}
		powerLimits = parts.isEmpty ? "firmware power limits" : parts.joined(separator: " · ")
		if let b = panelBrightness() { brightness = Double(b) } else { brightness = nil }
		if let config = try? Config.load() {
			autoProfile = config.autoProfile?.enabled == true
			if let a = config.autoProfile { autoText = "AC \(a.onAc ?? "-"), battery \(a.onBattery ?? "-")" }
			if let a = config.aura { aura = a }
		}
	}

	private func hold() { heldUntil = Date().addingTimeInterval(2.5) }

	private func keepBrightness() {
		guard let current = panelBrightness() else { return }  // the backlight isn't registered yet
		if !brightnessFound {
			brightnessFound = true
			keptBrightness = savedBrightness  // nothing saved yet: report the current level
			// Put back once, only right after boot: an app restart later finds the level the user has now.
			// From here on any change is the user's (keys, Control Center, the slider) and is only kept.
			if let saved = savedBrightness, ProcessInfo.processInfo.systemUptime < 300, abs(saved - current) > 0.005 {
				_ = setPanelBrightness(saved)
			}
			return
		}
		if let kept = keptBrightness, abs(current - kept) < 0.005 { return }
		keptBrightness = current
		client.run("brightness", String(format: "%.4f", current))
	}

	private func run(_ command: String, _ argument: String) {
		hold()
		client.run(command, argument) { [weak self] error in
			self?.error = error
			self?.heldUntil = .distantPast
			self?.refresh()
		}
	}

	func setProfile(_ name: String) { profile = name; run("profile", name) }
	func setAuto(_ on: Bool) { autoProfile = on; run("auto", on ? "on" : "off") }
	func setKeyboard(_ level: Int) { keyboardLight = level; run("kbd", "\(level)") }
	func setTouchpad(_ on: Bool) { touchpad = on; run("touchpad", on ? "on" : "off") }
	func setCharge(_ limit: Int) { chargeLimit = limit; run("charge", "\(limit)") }

	func setBrightness(_ value: Double) {
		hold()
		brightness = value
		if !setPanelBrightness(Float(value)) { error = "macOS has no brightness control for the panel" }
	}

	/// Aura changes are sent once the user stops changing them: APPLY writes the keyboard's storage.
	func setAura(_ update: (inout Aura) -> Void) {
		update(&aura)
		hold()
		auraSend?.cancel()
		let aura = self.aura
		let work = DispatchWorkItem { [weak self] in
			let encoder = JSONEncoder()
			encoder.keyEncodingStrategy = .convertToSnakeCase
			guard let data = try? encoder.encode(aura), let json = String(data: data, encoding: .utf8) else { return }
			self?.run("aura", json)
		}
		auraSend = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
	}
}
