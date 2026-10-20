// Settings rogd applies, in /Library/Application Support/RogControl/config.json.
// Mirrors asusd: one profile per performance mode (quiet / balanced / performance), each with
// fan curves, an energy preference and power "tunings" for AC and battery.
import Foundation

let configPath = "/Library/Application Support/RogControl/config.json"
let pidPath = "/var/run/rogd.pid"
let profileNames = ["quiet", "balanced", "performance"]

/// asusctl profile names <-> RogControl.kext performance modes (ASUS thermal policy).
func kextMode(forProfile name: String) -> String? {
	["quiet": "silent", "balanced": "balanced", "performance": "turbo"][name]
}

func profileName(forKextMode mode: String) -> String? {
	["silent": "quiet", "balanced": "balanced", "turbo": "performance"][mode]
}

struct Tuning: Codable, Equatable {
	var enabled = false
	var pl1: Int?               // sustained package power, W
	var pl2: Int?               // short boost power, W
	var fppt: Int?              // fast boost power, W
	var gpuDynamicBoost: Int?   // W
	var gpuTempTarget: Int?     // C
}

struct Tunings: Codable, Equatable {
	var ac: Tuning?
	var battery: Tuning?
}

struct FanCurves: Codable, Equatable {
	var enabled = false
	var cpu: [[Int]]?           // 8 x [temperature C, duty %]
	var gpu: [[Int]]?
}

struct Profile: Codable, Equatable {
	var epp: String?            // performance | balance_performance | balance_power | power
	var fanCurves: FanCurves?
	var tunings: Tunings?
}

struct AutoProfile: Codable, Equatable {
	var enabled = false
	var onAc: String?
	var onBattery: String?
}


struct Config: Codable, Equatable {
	var version = 1
	var cpuMaxMhz: Int?         // CPU frequency cap (0 or absent: none)
	var gpuClockMhz: [Int]?     // [min, max]; no macOS driver support yet, kept for later
	var chargeLimit: Int?       // %
	var panelOverdrive: Bool?   // not applied yet
	var autoProfile: AutoProfile?
	var profiles: [String: Profile] = [:]
	var aura: Aura?             // keyboard lighting (Aura.swift)

	static func load(_ path: String = configPath) throws -> Config {
		guard FileManager.default.fileExists(atPath: path) else { return Config() }
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		return try decoder.decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
	}

	func save(_ path: String = configPath) throws {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let dir = (path as NSString).deletingLastPathComponent
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
	}
}

/// 8 points as the kext's 16-byte curve: temperatures then duty percentages, both ascending.
func curveData(_ points: [[Int]]) -> Data? {
	guard points.count == 8, points.allSatisfy({ $0.count == 2 }) else { return nil }
	let temps = points.map { $0[0] }, duty = points.map { $0[1] }
	for i in 0..<8 {
		guard (0...120).contains(temps[i]), (0...100).contains(duty[i]) else { return nil }
		if i > 0 && (temps[i] < temps[i - 1] || duty[i] < duty[i - 1]) { return nil }
	}
	return Data((temps + duty).map { UInt8($0) })
}
