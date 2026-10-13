// Talking to RogControl.kext: its IORegistry properties are the status, setProperties the controls.
import Foundation
import IOKit
import IOKit.ps

final class RogKext {
	let service: io_service_t

	init?() {
		service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("RogControl"))
		if service == 0 { return nil }
	}

	deinit { IOObjectRelease(service) }

	func properties() -> [String: Any] {
		var props: Unmanaged<CFMutableDictionary>?
		guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
			let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }
		return dict
	}

	/// Returns the kext's result: kIOReturnBadArgument when one of the values was rejected
	/// (the others are still applied), kIOReturnNotPrivileged without root.
	@discardableResult
	func set(_ values: [String: Any]) -> kern_return_t {
		IORegistryEntrySetCFProperties(service, values as CFDictionary)
	}

	var mode: String? { properties()["PerformanceMode"] as? String }
}

func onBatteryPower() -> Bool {
	guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
		let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
	return type == kIOPMBatteryPowerKey
}

let tunableKeys: [(KeyPath<Tuning, Int?>, String)] = [
	(\.pl1, "PowerLimitPL1"), (\.pl2, "PowerLimitPL2"), (\.fppt, "PowerLimitFPPT"),
	(\.gpuDynamicBoost, "GPUDynamicBoost"), (\.gpuTempTarget, "GPUTempTarget"),
]

/// Everything one profile sets, as one kext request. A profile without a section leaves
/// that part to the firmware (stock fan curves, default power limits, CPU untouched).
func profileRequest(_ config: Config, profile name: String, onBattery: Bool, includeMode: Bool) -> [String: Any] {
	var req: [String: Any] = [:]
	let profile = config.profiles[name] ?? Profile()
	if includeMode, let mode = kextMode(forProfile: name) {
		req["PerformanceMode"] = mode
	}
	if let curves = profile.fanCurves, curves.enabled,
		let cpu = curves.cpu.flatMap(curveData), let gpu = curves.gpu.flatMap(curveData) {
		req["FanCurveCPU"] = cpu
		req["FanCurveGPU"] = gpu
	} else {
		req["FanCurvesReset"] = true
	}
	let tuning = (onBattery ? profile.tunings?.battery : profile.tunings?.ac) ?? Tuning()
	for (path, key) in tunableKeys {
		req[key] = tuning.enabled ? (tuning[keyPath: path] ?? 0) : 0
	}
	if config.cpuMaxMhz != nil || profile.epp != nil {
		req["CPUMaxFrequencyMHz"] = config.cpuMaxMhz ?? 0
		req["CPUEnergyPreference"] = profile.epp ?? "balance_performance"
	}
	if let limit = config.chargeLimit {
		req["ChargeLimit"] = limit
	}
	return req
}

func timestamp() -> String {
	let f = DateFormatter()
	f.dateFormat = "yyyy-MM-dd HH:mm:ss"
	return f.string(from: Date())
}
