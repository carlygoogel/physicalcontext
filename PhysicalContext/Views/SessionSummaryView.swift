import SwiftUI

// MARK: - Simulation display state

private enum SimState {
    case idle
    case running
    case result(SpiceAnalysisResult)
    case unavailable(String)
}

// MARK: - SessionSummaryView

struct SessionSummaryView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @State var session:  Session
    @State private var isSaving = false
    @State private var saved    = false
    @State private var simState = SimState.idle

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    Divider().background(Theme.border)
                    VStack(spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            whatYouDidCard
                            filesModifiedCard
                        }
                        componentChangesCard
                        simulationCard
                        if !session.deviations.isEmpty { deviationsSection }
                        additionalNotesSection
                        actions
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 720, height: 800)
        .onAppear { triggerSimulation() }
    }

    // MARK: - Component Changes
    // Reads Change events logged by KiCadSExprParser during the session.
    // KiCad 6+ S-expression coordinates are in mm (verified by KiCad docs:
    //   dev-docs.kicad.org/en/file-formats/sexpr-schematic).
    // Distance is Euclidean: sqrt(dx²+dy²) mm.

    private var componentChangesCard: some View {
        let added   = gather(type: .componentAdd,    prefix: "Added:")
        let removed = gather(type: .componentRemove, prefix: "Removed:")
        let moved   = gatherMoved()
        let valued  = gatherValueChanges()
        let hasAny  = !added.isEmpty || !removed.isEmpty || !moved.isEmpty || !valued.isEmpty

        return VStack(alignment: .leading, spacing: 12) {
            sectionLabel("COMPONENT CHANGES", icon: "cpu", color: Theme.accent)

            if !hasAny {
                Text("No component changes detected this session.")
                    .font(Theme.sans(11)).foregroundColor(Theme.textTertiary)
            } else {
                if !added.isEmpty {
                    changeGroup("ADDED", color: Theme.success, icon: "plus.circle.fill",
                                items: added, prefix: "+ ")
                }
                if !removed.isEmpty {
                    changeGroup("REMOVED", color: Theme.danger, icon: "minus.circle.fill",
                                items: removed, prefix: "− ")
                }
                if !valued.isEmpty {
                    changeGroup("VALUE CHANGED", color: Theme.warning, icon: "pencil.circle.fill",
                                items: valued, prefix: "~ ")
                }
                if !moved.isEmpty {
                    changeGroup("MOVED", color: Theme.textSecondary,
                                icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
                                items: moved, prefix: "↔ ")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .surfaceCard(14)
    }

    // Collect distinct component names from change events of a given type
    private func gather(type: Change.ChangeType, prefix: String) -> [String] {
        session.changes
            .filter { $0.changeType == type }
            .flatMap { c -> [String] in
                guard let r = c.description.range(of: prefix) else {
                    return c.description.isEmpty ? [] : [c.description]
                }
                return c.description[r.upperBound...]
                    .components(separatedBy: ", ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            .uniqued()
    }

    // Parse "Moved: R1 (10k), C4 (100nF) (+2 more)" entries
    private func gatherMoved() -> [String] {
        session.changes
            .filter { $0.description.hasPrefix("Moved:") }
            .flatMap { c -> [String] in
                c.description
                    .replacingOccurrences(of: "Moved: ", with: "")
                    .replacingOccurrences(of: #" \(\+?\d+ (?:more|total)\)"#, with: "",
                                          options: .regularExpression)
                    .components(separatedBy: ", ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            .uniqued()
    }

    // Parse "Changed: R5: 100→220" entries
    private func gatherValueChanges() -> [String] {
        session.changes
            .filter { $0.description.hasPrefix("Changed:") }
            .flatMap { c -> [String] in
                c.description
                    .replacingOccurrences(of: "Changed: ", with: "")
                    .components(separatedBy: ", ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            .uniqued()
    }

    private func changeGroup(_ title: String, color: Color, icon: String,
                              items: [String], prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9)).foregroundColor(color)
                Text(title).font(Theme.mono(8, .semibold)).foregroundColor(color).tracking(0.8)
            }
            ForEach(items, id: \.self) { item in
                HStack(spacing: 8) {
                    Rectangle().fill(color).frame(width: 2, height: 14).cornerRadius(1)
                    Text("\(prefix)\(item)")
                        .font(Theme.sans(12)).foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 4)
            }
        }
    }

    // MARK: - Simulation Card

    private var simulationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(simHeaderColor)
                Text("CIRCUIT VERIFICATION")
                    .font(Theme.mono(9, .semibold)).foregroundColor(simHeaderColor).tracking(1.2)
                Spacer()
                simBadge
            }

            switch simState {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.75)
                    Text("Running LTSpice simulation…")
                        .font(Theme.sans(12)).foregroundColor(Theme.textSecondary)
                }
                .padding(.vertical, 4)
            case .result(let r):
                simBody(r)
            case .unavailable(let msg):
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "gearshape").foregroundColor(Theme.textTertiary).frame(width: 16)
                    Text(msg).font(Theme.sans(11)).foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .surfaceCard(14)
    }

    @ViewBuilder
    private func simBody(_ r: SpiceAnalysisResult) -> some View {
        let passed = r.violations.isEmpty

        // ── Pass / Fail banner ────────────────────────────────────────────
        HStack(spacing: 12) {
            Image(systemName: passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                .font(.system(size: 22))
                .foregroundColor(passed ? Theme.success : Theme.danger)

            VStack(alignment: .leading, spacing: 4) {
                Text(passed ? "Circuit verified — nominal operation"
                            : "\(r.violations.count) violation(s) detected")
                    .font(Theme.sans(13, .semibold))
                    .foregroundColor(passed ? Theme.success : Theme.danger)

                HStack(spacing: 8) {
                    if let sim = r.simulator { infoPill(sim) }
                    if let t   = r.elapsedS  { infoPill(String(format: "%.2fs", t)) }
                    if let info = r.componentInfo, let st = info["sim_type"] {
                        infoPill(st.uppercased())
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .background((passed ? Theme.success : Theme.danger).opacity(0.08))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke((passed ? Theme.success : Theme.danger).opacity(0.2), lineWidth: 1))

        // ── Violations ────────────────────────────────────────────────────
        if !r.violations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                monoLabel("VIOLATIONS", Theme.danger)
                ForEach(r.violations) { v in
                    HStack(alignment: .top, spacing: 10) {
                        TagView(label: v.severity.uppercased(), color: severityColor(v.severity))
                            .frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.message).font(Theme.sans(11)).foregroundColor(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let val = v.value, let lim = v.limit {
                                Text("Measured \(fmtV(val))  ·  Limit \(fmtV(lim))")
                                    .font(Theme.mono(10)).foregroundColor(Theme.textTertiary)
                            }
                        }
                    }
                    .padding(9).background(Theme.surface).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(severityColor(v.severity).opacity(0.25), lineWidth: 1))
                }
            }
        }

        // ── Key measurements (.MEAS results) ─────────────────────────────
        // Categorised into voltages, currents, power so engineers can
        // quickly verify operating conditions against their spec.
        let voltages = r.measurements.filter { k, _ in
            let l = k.lowercased()
            return !l.contains("i_") && !l.contains("p_")
        }
        let currents = r.measurements.filter { k, _ in k.lowercased().contains("i_") }
        let power    = r.measurements.filter { k, _ in k.lowercased().contains("p_") }

        if !voltages.isEmpty || !currents.isEmpty || !power.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                monoLabel("MEASUREMENTS", Theme.textTertiary)
                if !voltages.isEmpty { measGrid(voltages, label: "Voltages",
                                                  unit: "V", color: Color(hex: "#5B8DEF")) }
                if !currents.isEmpty { measGrid(currents, label: "Currents",
                                                  unit: "A", color: Theme.success) }
                if !power.isEmpty    { measGrid(power, label: "Power",
                                                  unit: "W", color: Theme.warning) }
            }
        }

        // ── Node waveform extremes (from .raw file) ───────────────────────
        // These are the actual simulated waveform max/min/avg per node —
        // useful for finding unexpected voltage swings.
        if !r.rawTraces.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                monoLabel("NODE WAVEFORM EXTREMES", Theme.textTertiary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array(r.rawTraces.sorted(by: { $0.key < $1.key }).prefix(8)),
                            id: \.key) { key, trace in
                        nodeCard(name: key, trace: trace)
                    }
                }
            }
        }

        // ── Warnings ──────────────────────────────────────────────────────
        if !r.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                monoLabel("WARNINGS", Theme.warning)
                ForEach(r.warnings, id: \.self) { w in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9)).foregroundColor(Theme.warning)
                        Text(w).font(Theme.sans(10)).foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func measGrid(_ items: [String: Double], label: String,
                           unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.mono(8)).foregroundColor(color)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(Array(items.sorted(by: { $0.key < $1.key })), id: \.key) { k, v in
                    HStack {
                        Text(k.replacingOccurrences(of: "_", with: " "))
                            .font(Theme.mono(9)).foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(fmtV(v)) \(unit)")
                            .font(Theme.mono(10, .semibold)).foregroundColor(Theme.textPrimary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Theme.surfaceHigh).cornerRadius(5)
                }
            }
        }
    }

    private func nodeCard(name: String, trace: RawTrace) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(Theme.mono(9)).foregroundColor(Theme.textTertiary).lineLimit(1)
            HStack(spacing: 8) {
                Text("↑ \(fmtV(trace.max))").font(Theme.mono(10, .semibold)).foregroundColor(.white)
                Text("↓ \(fmtV(trace.min))").font(Theme.mono(10)).foregroundColor(Theme.textSecondary)
            }
            Text("avg \(fmtV(trace.avg))").font(Theme.mono(9)).foregroundColor(Theme.textTertiary)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceHigh).cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 0.5))
    }

    // MARK: - Trigger simulation on appear

    private func triggerSimulation() {
        // Use results already collected during the session
        if let last = session.spiceResults.last { applyResult(last); return }

        // SessionManager tracked the last watched schematic path
        if let path = SessionManager.shared.lastSimulatablePath,
           FileManager.default.fileExists(atPath: path) {
            runSim(path: path); return
        }

        // Recursive search for the schematic file
        let names = session.changes.compactMap { $0.file }
            .filter { $0.hasSuffix(".kicad_sch") || $0.hasSuffix(".asc") || $0.hasSuffix(".net") }
        if let name = names.first, let path = findFile(named: name) {
            runSim(path: path); return
        }

        simState = .unavailable(
            names.isEmpty
                ? "No schematic file found in session changes."
                : "Could not locate \(names.first!) — ensure the project folder is accessible."
        )
    }

    private func runSim(path: String) {
        simState = .running
        SpiceAnalyzer.shared.analyze(ascFilePath: path) { [self] result in
            guard let result else {
                simState = .unavailable("Simulation returned no result"); return
            }
            session.appendSpiceResult(result)
            sessionManager.updateArchivedSession(session)
            applyResult(result)
        }
    }

    private func applyResult(_ r: SpiceAnalysisResult) {
        simState = .result(r)
        // Auto-promote simulation violations to the Deviations section
        for v in r.violations {
            guard !session.deviations.contains(where: { $0.description == v.message }) else { continue }
            let sev: Deviation.Severity = v.severity == "major" ? .major
                : v.severity == "moderate" ? .moderate : .minor
            var dev = Deviation(description: v.message, severity: sev)
            dev.justification = "LTSpice simulation: measured \(v.value.map { fmtV($0) } ?? "n/a")"
            dev.confirmed = true
            session.deviations.append(dev)
        }
    }

    private func findFile(named name: String) -> String? {
        let roots = ["~/Documents","~/Desktop","~/Projects","~/kicad"]
            .map { ($0 as NSString).expandingTildeInPath }
        let fm = FileManager.default
        for root in roots {
            guard fm.fileExists(atPath: root) else { continue }
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root),
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in e {
                if url.lastPathComponent == name { return url.path }
                let depth = url.pathComponents.count - URL(fileURLWithPath: root).pathComponents.count
                if depth > 6 { e.skipDescendants() }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private var simHeaderColor: Color {
        switch simState {
        case .result(let r): return r.violations.isEmpty ? Theme.success : Theme.danger
        case .running:       return Theme.accent
        default:             return Theme.textTertiary
        }
    }

    private var simBadge: some View {
        Group {
            switch simState {
            case .running:
                badge("RUNNING", Theme.accent, Theme.accentDim)
            case .result(let r):
                let pass = r.violations.isEmpty
                badge(pass ? "PASSED" : "FAILED",
                      pass ? Theme.success : Theme.danger,
                      (pass ? Theme.success : Theme.danger).opacity(0.12))
            case .unavailable:
                badge("UNAVAILABLE", Theme.textTertiary, Theme.surfaceHigh)
            default:
                EmptyView()
            }
        }
    }

    private func badge(_ text: String, _ fg: Color, _ bg: Color) -> some View {
        Text(text).font(Theme.mono(8, .semibold)).foregroundColor(fg)
            .padding(.horizontal, 6).padding(.vertical, 2).background(bg).cornerRadius(4)
    }

    private func infoPill(_ text: String) -> some View {
        Text(text).font(Theme.mono(9)).foregroundColor(Theme.textTertiary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.surfaceHigh).cornerRadius(4)
    }

    private func monoLabel(_ text: String, _ color: Color) -> some View {
        Text(text).font(Theme.mono(8, .semibold)).foregroundColor(color).tracking(1)
    }

    private func severityColor(_ s: String) -> Color {
        switch s {
        case "major":    return Theme.danger
        case "moderate": return Theme.warning
        default:         return Color(hex: "#3B82F6")
        }
    }

    /// Format a value with appropriate SI scale
    private func fmtV(_ v: Double) -> String {
        let a = abs(v)
        if a == 0       { return "0" }
        if a >= 1000    { return String(format: "%.2fk", v / 1000) }
        if a >= 1       { return String(format: "%.4g", v) }
        if a >= 0.001   { return String(format: "%.2fm", v * 1000) }
        return String(format: "%.2fµ", v * 1_000_000)
    }

    // MARK: - Existing sections

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: sfSymbol(for: session.appBundleID))
                .font(.system(size: 18, weight: .medium)).foregroundColor(Theme.accent)
                .frame(width: 42, height: 42).background(Theme.accentDim).cornerRadius(10)
            VStack(alignment: .leading, spacing: 4) {
                Text("Session Summary — \(session.appName)")
                    .font(Theme.sans(16, .semibold)).foregroundColor(Theme.textPrimary)
                HStack(spacing: 6) {
                    hdrBadge("clock",             session.durationString)
                    hdrBadge("arrow.down.circle", "\(session.changes.count) saves")
                    if !session.deviations.isEmpty {
                        hdrBadge("exclamationmark.triangle",
                                 "\(session.deviations.count) deviations", Theme.warning)
                    }
                }
            }
            Spacer()
            if saved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.success)
                    Text("Saved").font(Theme.sans(12, .medium)).foregroundColor(Theme.success)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
    }

    private func hdrBadge(_ icon: String, _ value: String,
                            _ color: Color = Theme.textSecondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(value).font(Theme.mono(10))
        }
        .foregroundColor(color).padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.surface).cornerRadius(5)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 0.5))
    }

    private var whatYouDidCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("WHAT YOU DID", icon: "checkmark.circle", color: Theme.success)
            let bullets = summaryBullets()
            if bullets.isEmpty {
                Text("No changes recorded").font(Theme.sans(11)).foregroundColor(Theme.textTertiary)
            } else {
                ForEach(bullets, id: \.self) { b in
                    HStack(alignment: .top, spacing: 6) {
                        Text("—").font(Theme.mono(11)).foregroundColor(Theme.textTertiary)
                        Text(b).font(Theme.sans(12)).foregroundColor(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).surfaceCard(14)
    }

    private var filesModifiedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("FILES MODIFIED", icon: "doc", color: Theme.accent)
            let files = uniqueFiles()
            if files.isEmpty {
                Text("No files tracked").font(Theme.sans(11)).foregroundColor(Theme.textTertiary)
            } else {
                ForEach(files, id: \.self) { f in
                    Text(f).font(Theme.mono(11)).foregroundColor(Theme.textPrimary)
                }
            }
        }
        .frame(maxWidth: 220, alignment: .topLeading).surfaceCard(14)
    }

    private var deviationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("DEVIATIONS REQUIRING JUSTIFICATION",
                         icon: "exclamationmark.triangle", color: Theme.warning)
            ForEach($session.deviations) { $dev in DeviationCard(deviation: $dev) }
        }
    }

    private var additionalNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADDITIONAL NOTES").font(Theme.mono(9, .semibold))
                .foregroundColor(Theme.textTertiary).tracking(1.2)
            TextEditor(text: $session.additionalNotes)
                .font(Theme.sans(12)).foregroundColor(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(10).background(Theme.surface).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
                .frame(minHeight: 70)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Discard") {
                sessionManager.deleteSession(session)
                NSApp.keyWindow?.close()
            }.buttonStyle(GhostButtonStyle())

            Button {
                isSaving = true
                sessionManager.updateArchivedSession(session)
                withAnimation { isSaving = false; saved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    NSApp.keyWindow?.close()
                }
            } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().scaleEffect(0.7).frame(width: 12, height: 12) }
                    else { Image(systemName: "arrow.down.circle").font(.system(size: 12)) }
                    Text("Save Summary").font(Theme.sans(13, .medium))
                }
            }.buttonStyle(AccentButtonStyle())
        }
    }

    private func sectionLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundColor(color)
            Text(title).font(Theme.mono(9, .semibold)).foregroundColor(color).tracking(1.2)
        }
    }

    private func summaryBullets() -> [String] {
        var out = [String]()
        let saves = session.changes.filter { $0.changeType == .save }.count
        if saves > 0 { out.append("Saved \(saves) time\(saves == 1 ? "" : "s")") }
        out += session.notes.filter { $0.type == .manual }.prefix(4).map(\.content)
        if out.isEmpty { out = session.changes.prefix(4).map(\.description) }
        return out
    }

    private func uniqueFiles() -> [String] {
        Array(Set(session.changes.compactMap(\.file))).sorted()
    }

    private func sfSymbol(for bundleID: String) -> String {
        knownCADApps.first { $0.bundleID == bundleID }?.sfSymbol ?? "app"
    }
}

// MARK: - Array unique helper

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>(); return filter { seen.insert($0).inserted }
    }
}

// MARK: - DeviationCard

struct DeviationCard: View {
    @Binding var deviation: Deviation
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                TagView(label: deviation.severity.rawValue.uppercased(),
                        color: deviation.severityColor)
                Text(deviation.description).font(Theme.sans(12)).foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $deviation.confirmed) {
                Text("Confirmed — applies to my work")
                    .font(Theme.sans(11)).foregroundColor(Theme.textSecondary)
            }.toggleStyle(CheckboxToggleStyle())
            if deviation.confirmed {
                TextField("Your justification...", text: $deviation.justification, axis: .vertical)
                    .font(Theme.sans(11)).foregroundColor(Theme.textPrimary).textFieldStyle(.plain)
                    .padding(8).background(Theme.surfaceHigh).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 0.5))
                    .lineLimit(2...5)
            }
        }.surfaceCard(14)
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(configuration.isOn ? Theme.accent : Theme.surface)
                        .frame(width: 16, height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(configuration.isOn ? Theme.accent : Theme.border, lineWidth: 1))
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                configuration.label
            }
        }.buttonStyle(.plain)
    }
}
