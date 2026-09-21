import SwiftUI

struct ContentView: View {
    @State private var model: UninstallerModel
    @State private var confirming = false

    @MainActor init(model: UninstallerModel? = nil) { _model = State(initialValue: model ?? UninstallerModel()) }

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .scanning: ProgressView("Looking for AntennaHead and ControlBooth…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready, .running: chooser
            case .finished: finished
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .task { if model.phase == .scanning { model.scan() } }
    }

    // MARK: Chooser

    private var chooser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Uninstall AntennaHead and ControlBooth").font(.title2.bold())
                Text("Everything ticked below is moved to the Trash, not deleted, so you can bring it back with Finder’s Put Back. AntennaHead and ControlBooth are quit first.")
                    .foregroundStyle(.secondary)
                if let notice = model.notice { Text(notice).foregroundStyle(.red) }
                if !model.stillRunning.isEmpty {
                    Text("Couldn’t quit: \(model.stillRunning.joined(separator: ", ")). Quit them yourself, or use Force Quit below.")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Nothing to remove. No AntennaHead or ControlBooth files were found for this user.")
                    Button("Scan Again") { model.scan() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(UninstallItem.Group.allCases, id: \.self) { group in
                        let rows = model.items.filter { $0.group == group }
                        if !rows.isEmpty || group == .optional {
                            Section(group.rawValue) {
                                ForEach(rows) { item in row(item) }
                                if group == .optional && !model.items.contains(where: { $0.kind == .textToSpeech }) {
                                    Button("Choose text-to-speech folder…") { model.chooseTextToSpeechFolder() }
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Scan Again") { model.scan() }.disabled(model.phase == .running)
                Spacer()
                if model.phase == .running { ProgressView().controlSize(.small) }
                if !model.stillRunning.isEmpty {
                    Button("Force Quit Apps and Continue") { Task { await model.run(forceQuit: true) } }
                }
                Button("Move \(model.selectedCount) Item\(model.selectedCount == 1 ? "" : "s") to Trash…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedCount == 0 || model.phase == .running)
            }
            .padding(12)
        }
        .confirmationDialog("Move the selected items to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { Task { await model.run() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationMessage: String {
        var lines = ["\(model.selectedCount) item(s) will be moved to the Trash."]
        let names = model.runningAppNames
        if !names.isEmpty { lines.append("\(names.joined(separator: " and ")) will be quit first.") }
        let recordingsKept = model.items.contains { $0.kind == .recordings && !$0.selected }
        if recordingsKept { lines.append("Your recordings will be kept.") }
        return lines.joined(separator: " ")
    }

    private func row(_ item: UninstallItem) -> some View {
        Toggle(isOn: Binding(get: { item.selected }, set: { model.toggle(item.id, to: $0) })) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if let bytes = item.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .disabled(model.phase == .running)
    }

    // MARK: Finished

    private var finished: some View {
        VStack(spacing: 0) {
            let failures = model.results.filter { if case .failed = $0.outcome { true } else { false } }
            VStack(spacing: 8) {
                Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 36)).foregroundStyle(failures.isEmpty ? .green : .orange)
                Text(failures.isEmpty ? "Done" : "Finished with \(failures.count) problem(s)").font(.title3.bold())
                Text("Removed items are in the Trash. To restore something, open the Trash, select it and choose File ▸ Put Back.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(16)
            List(model.results) { r in
                HStack(alignment: .firstTextBaseline) {
                    switch r.outcome {
                    case .done: Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    case .failed: Image(systemName: "xmark.octagon").foregroundStyle(.red)
                    }
                    VStack(alignment: .leading) {
                        Text(r.title)
                        switch r.outcome {
                        case .skipped(let m), .failed(let m): Text(m).font(.caption).foregroundStyle(.secondary)
                        case .done: EmptyView()
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Trash") { model.openTrash() }
                Spacer()
                Button("Scan Again") { model.scan() }
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}
