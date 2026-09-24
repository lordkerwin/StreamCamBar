import SwiftUI

@main
struct StreamCamBarApp: App {
    @StateObject private var model = CameraModel()

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(model: model)
        } label: {
            Image(systemName: model.connected ? "web.camera.fill" : "web.camera")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ControlPanel: View {
    @ObservedObject var model: CameraModel
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.connected {
                ProfileBar(model: model)
                Divider()
                exposureSection
                Divider()
                whiteBalanceSection
                Divider()
                focusSection
                DisclosureGroup("Image", isExpanded: $showMore) { imageSection.padding(.top, 6) }
                    .font(.headline)
                Divider()
                footer
            } else {
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                Button("Retry") { model.scheduleReconnect(after: 0) }
            }
            Divider()
            HStack {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack {
            Circle().fill(model.connected ? .green : .secondary).frame(width: 8, height: 8)
            Text(model.name).font(.headline)
            Spacer()
        }
    }

    // MARK: Sections

    @ViewBuilder private var exposureSection: some View {
        section("Exposure") {
            Toggle("Auto", isOn: Binding(get: { model.autoExposure }, set: { model.setAutoExposure($0) }))
        }
        if model.supports(.exposureTime) {
            LogSlider(label: "Shutter", spec: .exposureTime, model: model, format: shutterText)
                .disabled(model.autoExposure)
        }
        if model.supports(.gain) {
            ControlSlider(label: "Gain", spec: .gain, model: model).disabled(model.autoExposure)
        }
        if model.supports(.brightness) {
            ControlSlider(label: "Brightness", spec: .brightness, model: model)
        }
    }

    @ViewBuilder private var whiteBalanceSection: some View {
        let auto = model.value(.autoWhiteBalance) != 0
        section("White Balance") {
            Toggle("Auto", isOn: Binding(get: { auto }, set: { model.setAuto(.autoWhiteBalance, $0) }))
        }
        if model.supports(.whiteBalance) {
            ControlSlider(label: "Temp", spec: .whiteBalance, model: model, format: { "\($0)K" }).disabled(auto)
        }
    }

    @ViewBuilder private var focusSection: some View {
        if model.supports(.autoFocus) {
            let auto = model.value(.autoFocus) != 0
            section("Focus") {
                Toggle("Auto", isOn: Binding(get: { auto }, set: { model.setAuto(.autoFocus, $0) }))
            }
            if model.supports(.focus) {
                ControlSlider(label: "Focus", spec: .focus, model: model).disabled(auto)
            }
        }
        if model.supports(.zoom) {
            ControlSlider(label: "Zoom", spec: .zoom, model: model, format: { String(format: "%.1f×", Double($0) / 100) })
        }
    }

    @ViewBuilder private var imageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([UVCControlSpec.contrast, .saturation, .sharpness], id: \.self) { spec in
                if model.supports(spec) { ControlSlider(label: spec.name, spec: spec, model: model) }
            }
            if model.supports(.backlight) {
                Toggle("Backlight compensation", isOn: Binding(
                    get: { model.value(.backlight) != 0 }, set: { model.set(.backlight, $0 ? 1 : 0) }))
            }
            if model.supports(.powerLine), let r = model.range(.powerLine) {
                Picker("Anti-flicker", selection: Binding(get: { model.value(.powerLine) }, set: { model.set(.powerLine, $0) })) {
                    ForEach(r.min...r.max, id: \.self) { v in
                        Text(["Off", "50 Hz", "60 Hz", "Auto"][safe: v] ?? "\(v)").tag(v)
                    }
                }
            }
        }
        .font(.body)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Restore my settings on connect, wake & call start", isOn: $model.restoreSettings)
            HStack {
                Button("Reset to defaults") { model.resetToDefaults() }
                Button("Re-apply") { model.reapply() }
            }
        }
        .controlSize(.small)
    }

    private func section<C: View>(_ title: String, @ViewBuilder trailing: () -> C) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            trailing().toggleStyle(.switch).controlSize(.mini)
        }
    }
}

private func shutterText(_ v: Int) -> String {
    // UVC exposure time is in 100µs units.
    let seconds = Double(v) / 10_000
    return seconds >= 1 ? String(format: "%.1fs", seconds) : "1/\(Int((1 / seconds).rounded()))s"
}

struct ControlSlider: View {
    let label: String
    let spec: UVCControlSpec
    @ObservedObject var model: CameraModel
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        let r = model.range(spec) ?? UVCRange(min: 0, max: 255, res: 1, def: 0)
        HStack {
            Text(label).frame(width: 72, alignment: .leading)
            Slider(
                value: Binding(get: { Double(model.value(spec)) }, set: { model.set(spec, Int($0.rounded())) }),
                in: Double(r.min)...Double(max(r.max, r.min + 1)))
                .controlSize(.small)
            Text(format(model.value(spec))).monospacedDigit().frame(width: 48, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// Exposure spans ~3 orders of magnitude, so a log scale is far more usable.
struct LogSlider: View {
    let label: String
    let spec: UVCControlSpec
    @ObservedObject var model: CameraModel
    var format: (Int) -> String

    var body: some View {
        let r = model.range(spec) ?? UVCRange(min: 1, max: 2047, res: 1, def: 1)
        let lo = log(Double(max(r.min, 1))), hi = log(Double(max(r.max, r.min + 1)))
        HStack {
            Text(label).frame(width: 72, alignment: .leading)
            Slider(
                value: Binding(get: { log(Double(max(model.value(spec), 1))) }, set: { model.set(spec, Int(exp($0).rounded())) }),
                in: lo...hi)
                .controlSize(.small)
            Text(format(model.value(spec))).monospacedDigit().frame(width: 48, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct ProfileBar: View {
    @ObservedObject var model: CameraModel
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(model.profiles) { p in
                        Button { model.applyProfile(p) } label: {
                            if p.id == model.activeProfileID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                    if !model.profiles.isEmpty { Divider() }
                    Button("Save Current as New Profile…") { newName = ""; naming = true }
                    if let active = model.activeProfile {
                        Button("Update “\(active.name)”") { model.updateActiveProfile() }
                        Button("Delete “\(active.name)”") { model.deleteActiveProfile() }
                    }
                } label: {
                    Label(menuTitle, systemImage: "slider.horizontal.3")
                }
                .fixedSize()
                Spacer()
                if model.activeProfileModified {
                    Button("Update") { model.updateActiveProfile() }.controlSize(.small)
                }
            }

            if naming {
                HStack {
                    TextField("Profile name, e.g. Daytime", text: $newName).onSubmit(save)
                    Button("Save", action: save).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { naming = false }
                }
                .controlSize(.small)
            }

            if let active = model.activeProfile {
                HStack {
                    Toggle("Auto-switch to this profile at", isOn: Binding(
                        get: { active.startMinutes != nil },
                        set: { model.setSchedule($0 ? currentMinutes() : nil) }))
                    Spacer()
                    if let minutes = active.startMinutes {
                        DatePicker("", selection: Binding(
                            get: { dateFrom(minutes: minutes) },
                            set: { model.setSchedule(minutesFrom($0)) }),
                            displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }
                .controlSize(.small)
                .font(.callout)
            }
        }
    }

    private var menuTitle: String {
        guard let active = model.activeProfile else { return model.profiles.isEmpty ? "Profiles" : "No profile" }
        return model.activeProfileModified ? "\(active.name) (modified)" : active.name
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.saveProfile(named: name)
        naming = false
    }
}

private func currentMinutes() -> Int { minutesFrom(Date()) }

private func minutesFrom(_ date: Date) -> Int {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

private func dateFrom(minutes: Int) -> Date {
    Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
}
