// The panel under the menu bar item.
import SwiftUI

private let profiles = [("quiet", "Quiet"), ("balanced", "Balanced"), ("performance", "Performance")]
private let auraModeNames = [("static", "Static"), ("breathe", "Breathe"), ("rainbow_cycle", "Rainbow cycle"),
	("rainbow_wave", "Rainbow wave"), ("pulse", "Pulse")]
private let swatches = ["ffffff", "ff0000", "ff6a00", "ffd000", "00ff00", "00ffff", "0040ff", "9b26b6", "ff00aa"]

private func colour(_ hex: String) -> Color {
	let c = rgb(hex) ?? [255, 255, 255]
	return Color(red: Double(c[0]) / 255, green: Double(c[1]) / 255, blue: Double(c[2]) / 255)
}

struct PanelSection<Content: View>: View {
	let title: String
	@ViewBuilder let content: Content
	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title).font(.caption).foregroundStyle(.secondary)
			content
		}
	}
}

struct Reading: View {
	let label: String
	let value: String
	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			Text(label).font(.caption2).foregroundStyle(.secondary)
			Text(value).font(.system(.title3, design: .rounded).monospacedDigit())
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

struct PanelView: View {
	@ObservedObject var model: StatusModel
	@SwiftUI.State private var hexField = ""

	init(model: StatusModel) {
		self.model = model
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack {
				Text("RogControl").font(.headline)
				Spacer()
				Text(model.onBattery ? "Battery" : "AC").font(.caption).foregroundStyle(.secondary)
			}
			if !model.available {
				Text("RogControl.kext is not loaded.").foregroundStyle(.secondary)
			} else {
				HStack {
					Reading(label: "CPU", value: model.cpuTemp.map { "\($0) °C" } ?? "–")
					Reading(label: "GPU", value: model.gpuTemp.map { "\($0) °C" } ?? "–")
					Reading(label: "CPU fan", value: model.cpuFan.map { "\($0)" } ?? "–")
					Reading(label: "GPU fan", value: model.gpuFan.map { "\($0)" } ?? "–")
				}

				PanelSection(title: "Profile") {
					Picker("", selection: Binding(get: { model.profile }, set: { model.setProfile($0) })) {
						ForEach(profiles, id: \.0) { Text($0.1).tag($0.0) }
					}
					.pickerStyle(.segmented).labelsHidden()
					Toggle(isOn: Binding(get: { model.autoProfile }, set: { model.setAuto($0) })) {
						Text("Switch with the power source").font(.callout)
						+ Text(model.autoText.isEmpty ? "" : "  \(model.autoText)").font(.caption).foregroundColor(.secondary)
					}
					.toggleStyle(.checkbox)
					Text("\(model.cpuLimit) · \(model.powerLimits)").font(.caption).foregroundStyle(.secondary)
				}

				PanelSection(title: "Keyboard") {
					Picker("", selection: Binding(get: { model.keyboardLight ?? -1 }, set: { model.setKeyboard($0) })) {
						Text("Off").tag(0)
						Text("Low").tag(1)
						Text("Med").tag(2)
						Text("High").tag(3)
					}
					.pickerStyle(.segmented).labelsHidden()
					HStack {
						Picker("", selection: Binding(get: { model.aura.mode ?? "static" }, set: { m in model.setAura { $0.mode = m } })) {
							ForEach(auraModeNames, id: \.0) { Text($0.1).tag($0.0) }
						}
						.labelsHidden().frame(width: 130)
						if ["breathe", "rainbow_cycle", "rainbow_wave", "pulse"].contains(model.aura.mode ?? "static") {
							Picker("", selection: Binding(get: { model.aura.speed ?? "med" }, set: { s in model.setAura { $0.speed = s } })) {
								Text("Slow").tag("low")
								Text("Med").tag("med")
								Text("Fast").tag("high")
							}
							.pickerStyle(.segmented).labelsHidden()
						}
					}
					if model.aura.zones == nil, !["rainbow_cycle", "rainbow_wave"].contains(model.aura.mode ?? "static") {
						HStack(spacing: 6) {
							ForEach(swatches, id: \.self) { hex in
								Circle()
									.fill(colour(hex))
									.frame(width: 18, height: 18)
									.overlay(Circle().stroke(Color.primary.opacity((model.aura.colour ?? "ffffff") == hex ? 0.9 : 0.15), lineWidth: 2))
									.onTapGesture { model.setAura { $0.colour = hex } }
							}
							TextField("rrggbb", text: $hexField)
								.textFieldStyle(.roundedBorder)
								.frame(width: 70)
								.onSubmit {
									let hex = hexField.lowercased().replacingOccurrences(of: "#", with: "")
									if rgb(hex) != nil { model.setAura { $0.colour = hex } }
								}
						}
					} else if let zones = model.aura.zones {
						HStack(spacing: 6) {
							Text("Zones").font(.caption).foregroundStyle(.secondary)
							ForEach(zones.indices, id: \.self) { Circle().fill(colour(zones[$0])).frame(width: 18, height: 18) }
							Text("(rogctl aura zones)").font(.caption).foregroundStyle(.secondary)
						}
					}
					if !model.keyboardFound {
						Text("Keyboard not found yet").font(.caption).foregroundStyle(.secondary)
					}
				}

				PanelSection(title: "Display and touchpad") {
					if let value = model.brightness {
						HStack {
							Image(systemName: "sun.min")
							Slider(value: Binding(get: { value }, set: { model.setBrightness($0) }), in: 0...1)
							Image(systemName: "sun.max")
						}
					} else {
						Text("No brightness control (NVIDIA driver needs nvrmacpibl=1)").font(.caption).foregroundStyle(.secondary)
					}
					Toggle("Touchpad (Fn+F10)", isOn: Binding(get: { model.touchpad }, set: { model.setTouchpad($0) }))
						.toggleStyle(.checkbox)
				}

				PanelSection(title: "Battery") {
					Picker("Charge limit", selection: Binding(get: { model.chargeLimit ?? 100 }, set: { model.setCharge($0) })) {
						ForEach([60, 70, 80, 90, 100], id: \.self) { Text("\($0)%").tag($0) }
					}
					.frame(width: 200)
				}
			}

			if let error = model.error {
				Text(error).font(.caption).foregroundStyle(.red)
			}
			Divider()
			HStack {
				Button("Settings file…") {
					NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)])
				}
				Spacer()
				Button("Quit") { NSApp.terminate(nil) }
			}
			.buttonStyle(.borderless)
		}
		.padding(14)
		.frame(width: 360)
	}
}
