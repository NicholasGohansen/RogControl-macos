// Aura keyboard lighting for the N-KEY keyboard (0b05:19b6), with the packets asusd builds
// (asusctl rog-aura): effect 5D B3, SET 5D B5, APPLY 5D B4, power states 5D BD 01. The kext
// sends them as output reports; APPLY stores the effect in the keyboard, so it is only sent
// when the settings change (and once at start).
import Foundation

struct AuraPowerState: Codable, Equatable {
	var boot = true
	var awake = true
	var sleep = true
	var shutdown = true
}

/// Which lights are on in which power state (asusd "enabled" states).
struct AuraPower: Codable, Equatable {
	var keyboard = AuraPowerState()
	var lightbar = AuraPowerState()
}

struct Aura: Codable, Equatable {
	var mode: String?            // see auraModes
	var colour: String?          // "rrggbb"
	var colour2: String?         // second colour (breathe)
	var speed: String?           // low / med / high
	var direction: String?       // right / left / up / down
	var zones: [String]?         // four colours, left to right, instead of `colour` (multizone)
	var brightness: String?      // off / low / med / high: keyboard light until Fn+F2/F3 set one
	var power: AuraPower?
}

let auraModes: [String: UInt8] = [
	"static": 0, "breathe": 1, "rainbow_cycle": 2, "rainbow_wave": 3, "star": 4, "rain": 5,
	"highlight": 6, "laser": 7, "ripple": 8, "pulse": 10, "comet": 11, "flash": 12,
]
/// The modes the G713P's keyboard has (asusctl aura_support.ron), in Aura key order.
let auraCycle = ["static", "breathe", "rainbow_cycle", "rainbow_wave", "pulse"]
let auraSpeeds: [String: UInt8] = ["low": 0xE1, "med": 0xEB, "high": 0xF5]
let auraDirections: [String: UInt8] = ["right": 0, "left": 1, "up": 2, "down": 3]
let auraBrightness: [String: Int] = ["off": 0, "low": 1, "med": 2, "high": 3]

/// "ffa000" or "#ffa000" -> (r, g, b)
func rgb(_ hex: String?) -> [UInt8]? {
	guard var text = hex?.lowercased() else { return nil }
	if text.hasPrefix("#") { text.removeFirst() }
	guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
	return [UInt8(value >> 16), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

extension AuraPower {
	/// asusd LaptopAuraPower::new_to_bytes() for 2021+ keyboards
	var bytes: [UInt8] {
		func bit(_ on: Bool, _ shift: Int) -> UInt32 { on ? 1 << shift : 0 }
		let k = keyboard, l = lightbar
		let a = bit(k.boot, 1) | bit(k.awake, 3) | bit(k.sleep, 5) | bit(k.shutdown, 7) |
			bit(l.boot, 9) | bit(l.awake, 10) | bit(l.sleep, 11) | bit(l.shutdown, 12)
		return [0x5D, 0xBD, 0x01, UInt8(a & 0xFF), UInt8((a >> 8) & 0xFF), UInt8((a >> 16) & 0xFF), UInt8(a >> 24)]
	}
}

extension Aura {
	/// Problems with the settings, empty when they can be sent.
	var problems: [String] {
		var out: [String] = []
		if let mode = mode, auraModes[mode] == nil { out.append("unknown mode \(mode)") }
		if colour != nil && rgb(colour) == nil { out.append("colour must be rrggbb") }
		if colour2 != nil && rgb(colour2) == nil { out.append("colour2 must be rrggbb") }
		if let speed = speed, auraSpeeds[speed] == nil { out.append("speed is low, med or high") }
		if let dir = direction, auraDirections[dir] == nil { out.append("direction is right, left, up or down") }
		if let zones = zones, zones.count != 4 || zones.contains(where: { rgb($0) == nil }) { out.append("zones needs 4 rrggbb colours") }
		if let b = brightness, auraBrightness[b] == nil { out.append("brightness is off, low, med or high") }
		return out
	}

	/// Effect, SET and APPLY (per zone when zones are set), then the power states.
	func packets() -> [Data] {
		guard problems.isEmpty, let mode = auraModes[mode ?? "static"] else { return [] }
		let speed = auraSpeeds[self.speed ?? "med"] ?? 0xEB
		let direction = auraDirections[self.direction ?? "right"] ?? 0
		let second = rgb(colour2) ?? [0, 0, 0]
		func effect(zone: UInt8, _ c: [UInt8]) -> [UInt8] {
			[0x5D, 0xB3, zone, mode, c[0], c[1], c[2], speed, direction, 0, second[0], second[1], second[2], 0, 0, 0, 0]
		}
		let set: [UInt8] = [0x5D, 0xB5] + [UInt8](repeating: 0, count: 15)
		let apply: [UInt8] = [0x5D, 0xB4] + [UInt8](repeating: 0, count: 15)
		var out: [[UInt8]] = []
		if let zones = zones?.compactMap(rgb), zones.count == 4 {
			for (i, c) in zones.enumerated() { out += [effect(zone: UInt8(i + 1), c), set, apply] }
		} else {
			out += [effect(zone: 0, rgb(colour) ?? [0xFF, 0xFF, 0xFF]), set, apply]
		}
		out.append((power ?? AuraPower()).bytes)
		return out.map { Data($0) }
	}
}
