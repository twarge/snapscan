import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ScannerEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow
    /// The window's undo manager, so ⌘Z and the Edit menu work as they do
    /// anywhere else — and so a focused text field keeps its own undo.
    @Environment(\.undoManager) private var undoManager
    @State private var library = ScanLibrary.shared
    /// nil = the in-progress scan session; otherwise a saved PDF to preview.
    @State private var selection: URL?
    @State private var enlargedPage: ScannedPage?

    // Document name field
    @State private var draftName = ""
    @State private var lastEngineName = ""
    @FocusState private var nameFieldFocused: Bool

    // Page grid
    @State private var selectedPages: Set<UUID> = []
    @FocusState private var gridFocused: Bool
    @AppStorage("thumbnailSize") private var thumbnailSize = 160.0
    @State private var pinchScale: CGFloat = 1

    // Sidebar inline rename
    @State private var renamingDocumentID: UUID?
    @State private var renameDraft = ""
    @State private var renamePendingID: UUID?
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 480)
        .toolbar { toolbarContent }
        .navigationTitle("SnapScan")
        .navigationSubtitle(subtitle)
        .task {
            WindowOpener.shared.openWindowAction = openWindow
            promptForDestinationIfFirstRun()
            library.setMonitoredFolder(engine.settings.destinationURL)
        }
        .onChange(of: engine.settings.destinationPath) {
            library.setMonitoredFolder(engine.settings.destinationURL)
        }
        .onChange(of: engine.documentURL) {
            library.refresh()
            if engine.documentURL != nil { selection = nil }
        }
        .onChange(of: engine.pages.count) { library.refresh() }
        .onChange(of: library.documents) {
            // The previewed scan may have been deleted or moved away; don't
            // keep showing a file that no longer exists.
            guard let selected = selection else { return }
            let stillKnown =
                library.documents.contains { $0.url == selected }
                || engine.documentURL == selected
                || engine.backgroundDocuments.contains { $0.url == selected }
            if !stillKnown { selection = nil }
        }
        .onChange(of: engine.documentDisplayName) { _, newName in
            // Follow the engine's name unless the user is mid-edit.
            if draftName == lastEngineName { draftName = newName }
            lastEngineName = newName
        }
        .onChange(of: engine.status) { _, newStatus in
            // A fresh document's scan just started: offer the proposed name,
            // focused and fully selected, so typing + return renames it.
            if case .scanning = newStatus, engine.pages.isEmpty, selection == nil {
                draftName = engine.documentDisplayName
                lastEngineName = draftName
                nameFieldFocused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                }
            }
        }
        .sheet(item: $enlargedPage) { page in
            pagePreview(page)
        }
        .focusedSceneValue(\.scanActions, menuActions)
    }

    /// The window's half of the File menu.
    private var menuActions: ScanActions {
        ScanActions(
            scan: { Task { await engine.scan() } },
            done: { finalizeDocument() },
            discard: { discardScan() },
            reveal: {
                guard let url = selection ?? engine.documentURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            share: {
                guard let url = selection ?? engine.documentURL,
                    let anchor = NSApp.keyWindow?.contentView
                else { return }
                NSSharingServicePicker(items: [url])
                    .show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
            },
            deletePages: { deleteSelectedPages() },
            selectAllPages: { selectedPages = Set(engine.pages.map(\.id)) },
            rename: { beginRenameFromMenu() },
            canScan: !engine.isBusy && engine.scannerPresent,
            canFinish: !engine.isBusy && !engine.isSaving && !engine.pages.isEmpty,
            hasDocument: engine.current != nil,
            canDeletePages: canDeletePages,
            hasPages: !engine.pages.isEmpty,
            canRename: selection != nil || engine.current != nil,
            target: selection ?? engine.documentURL)
    }

    /// The page grid is what the keyboard is pointed at: it's on screen, and
    /// no text field or sheet has the keys. The grid's ⌫, ⌦ and ⎋ are caught
    /// before any view sees them, so they must stand aside whenever typing
    /// would otherwise lose the key.
    private var pageGridHasKeys: Bool {
        selection == nil && enlargedPage == nil && !nameFieldFocused
            && !renameFieldFocused
    }

    private var canDeletePages: Bool {
        !selectedPages.isEmpty && !engine.isBusy && pageGridHasKeys
    }

    /// Rename whatever the window is showing: the selected saved scan opens
    /// its inline field, and the scan being built puts the caret in the name
    /// field above the pages.
    private func beginRenameFromMenu() {
        if let selection,
            let document = library.documents.first(where: { $0.url == selection }) {
            renamePendingID = nil
            beginRename(document)
        } else if engine.current != nil {
            nameFieldFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
            }
        }
    }

    /// First run: ask where scans should go. The selection doubles as the
    /// sandbox grant for that folder (stored as a security-scoped bookmark);
    /// cancelling falls back to ~/Downloads, which the downloads entitlement
    /// covers without a grant.
    private func promptForDestinationIfFirstRun() {
        guard !engine.settings.promptedForFolder,
            engine.settings.destinationBookmark == nil
        else { return }
        // A modal panel would hang a headless test host (the app is the
        // TEST_HOST when running unit tests, including on CI).
        guard NSClassFromString("XCTestCase") == nil,
            ProcessInfo.processInfo.environment["SNAPSCAN_SUPPRESS_FIRST_RUN"] == nil
        else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose where SnapScan saves your scanned PDFs."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            engine.setDestination(url)
        }
        engine.settings.promptedForFolder = true
    }

    private var subtitle: String {
        switch engine.status {
        case .detecting: "Looking for scanner…"
        case .scanning(let page): "Scanning page \(page)…"
        case .noScanner: "Scanner not connected"
        case .idle:
            if engine.isSaving {
                "Saving…"
            } else if engine.isNaming {
                "Naming…"
            } else if engine.isProcessingAnywhere {
                "Straightening…"
            } else {
                engine.scannerName ?? ""
            }
        }
    }

    /// True while there is a scan session to show or name.
    private var sessionActive: Bool {
        if !engine.pages.isEmpty { return true }
        if case .scanning = engine.status { return true }
        return false
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if sessionActive {
                    currentScanRow
                }
                ForEach(engine.backgroundDocuments) { document in
                    processingRow(document)
                }
                ForEach(library.documents.filter { !engine.inFlightURLs.contains($0.url) }) { document in
                    DragRow(
                        url: document.url,
                        interceptsClicks: renamingDocumentID != document.id
                    ) {
                        rowClicked(document)
                    } onMoved: { url in
                        engine.documentWasMoved(url)
                        if selection == url { selection = nil }
                        library.refresh()
                    } onTrash: { trashedTo in
                        if selection == document.url { selection = nil }
                        library.refresh()
                        guard let trashedTo else { return }
                        registerUndo("Move to Trash") { _ in
                            try? FileManager.default.moveItem(
                                at: trashedTo, to: document.url)
                            library.refresh()
                        }
                    } onRename: {
                        // Deliberately without selecting the row: renaming
                        // shouldn't swap what the detail pane is showing, and
                        // navigating away would finalize an open scan.
                        renamePendingID = nil
                        beginRename(document)
                    } content: {
                        documentRow(document, isSelected: selection == document.url)
                    }
                    .frame(height: 44)
                }
                if library.documents.isEmpty && engine.pages.isEmpty {
                    Text("No scans yet")
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
            }
            .padding(8)
        }
    }

    /// Click selects; a second click on the already-selected row (after a
    /// pause, Finder-style) begins an inline rename.
    private func rowClicked(_ document: ScanDocument) {
        if selection == document.url, renamingDocumentID == nil {
            renamePendingID = document.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard renamePendingID == document.id, selection == document.url else { return }
                renamePendingID = nil
                beginRename(document)
            }
        } else {
            // Navigating away finalizes the active scan into a saved
            // document — its row joins the list like any other scan.
            // Mid-scan the session must stay open, so the current-scan row
            // remains as the way back until the batch finishes.
            if selection == nil, sessionActive, !engine.isBusy {
                engine.done()
            }
            selection = document.url
            renamePendingID = nil
            commitOrCancelRename()
        }
    }

    private func beginRename(_ document: ScanDocument) {
        renameDraft = document.name
        renamingDocumentID = document.id
        renameFieldFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private func commitOrCancelRename() {
        renamingDocumentID = nil
        renameFieldFocused = false
    }

    private func performRename(_ document: ScanDocument) {
        defer { commitOrCancelRename() }
        let cleaned = ScannerEngine.sanitizeFileName(renameDraft)
        guard !cleaned.isEmpty, cleaned != document.name else { return }
        let directory = document.url.deletingLastPathComponent()
        var destination = directory.appendingPathComponent("\(cleaned).pdf")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(cleaned) (\(counter)).pdf")
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: document.url, to: destination)
            let previous = document.url
            if selection == document.url { selection = destination }
            library.refresh()
            registerUndo("Rename") { _ in
                try? FileManager.default.moveItem(at: destination, to: previous)
                if selection == destination { selection = previous }
                library.refresh()
            }
        } catch {
            engine.lastError = "Couldn't rename: \(error.localizedDescription)"
        }
    }

    private var currentScanRow: some View {
        Button {
            selection = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: engine.documentOpen ? "doc.badge.ellipsis" : "doc.viewfinder")
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.documentURL?.deletingPathExtension().lastPathComponent
                        ?? "Current Scan")
                        .lineLimit(1)
                    Text("\(engine.pages.count) page\(engine.pages.count == 1 ? "" : "s")"
                        + (engine.documentOpen ? " — scanning adds more" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selection == nil ? Color.accentColor.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = engine.documentURL {
                Button("Copy PDF") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                ShareLink(item: url)
                Divider()
            }
            Button("Discard Scan", role: .destructive) { discardScan() }
        }
    }

    /// Throws away the scan in progress — the PDF goes to the Trash.
    private func discardScan() {
        let discarded = engine.discardCurrent()
        selection = nil
        selectedPages = []
        draftName = ""
        guard let discarded else { return }
        registerUndo("Discard Scan") { engine in
            engine.restore(discarded)
            selection = nil
        }
    }

    /// A finalized document whose straightening/saving is still draining.
    private func processingRow(_ document: ActiveDocument) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.displayName.isEmpty ? "Processing…" : document.displayName)
                    .lineLimit(1)
                Text("Straightening \(document.processingRemaining) page\(document.processingRemaining == 1 ? "" : "s")…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 44)
    }

    private func documentRow(_ document: ScanDocument, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                if renamingDocumentID == document.id {
                    TextField("Name", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .focused($renameFieldFocused)
                        .onSubmit { performRename(document) }
                        .onExitCommand { commitOrCancelRename() }
                } else {
                    Text(document.name)
                        .lineLimit(1)
                }
                Text(document.modified.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selection {
            PDFPreview(url: selection) {
                // The file became unopenable while shown — drop it from the
                // list; the library change clears the selection below.
                library.refresh()
            }
            .ignoresSafeArea()
        } else if !sessionActive {
            emptyState
        } else {
            let cellSize = min(420, max(80, thumbnailSize * pinchScale))
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: cellSize, maximum: cellSize * 1.35),
                            spacing: 16)
                    ],
                    spacing: 16
                ) {
                    ForEach(Array(engine.pages.enumerated()), id: \.element.id) { index, page in
                        pageCell(page, number: index + 1, size: cellSize)
                    }
                    if case .scanning = engine.status {
                        liveScanCell(size: cellSize)
                    }
                }
                .padding()
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in pinchScale = value.magnification }
                    .onEnded { _ in
                        thumbnailSize = min(420, max(80, thumbnailSize * pinchScale))
                        pinchScale = 1
                    }
            )
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .background {
                PageGridKeys(
                    canDelete: canDeletePages,
                    canDeselect: !selectedPages.isEmpty && pageGridHasKeys,
                    delete: { deleteSelectedPages() },
                    deselect: { selectedPages = [] })
            }
            .safeAreaInset(edge: .top) { documentHeader }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
    }

    private func deleteSelectedPages() {
        guard !selectedPages.isEmpty else { return }
        let deletion = engine.deletePages(withIDs: selectedPages)
        selectedPages = []
        guard let deletion else { return }
        registerUndo("Delete Pages") { engine in engine.restore(deletion) }
    }

    /// Registers an inverse for a destructive action. The handler runs on the
    /// main actor: undo arrives through the menu, which is already there.
    private func registerUndo(
        _ name: String, _ inverse: @escaping (ScannerEngine) -> Void
    ) {
        guard let undoManager else { return }
        undoManager.setActionName(name)
        undoManager.registerUndo(withTarget: ScannerEngine.shared) { engine in
            MainActor.assumeIsolated { inverse(engine) }
        }
    }

    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "character.cursor.ibeam")
                    .foregroundStyle(.secondary)
                TextField("Document name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFieldFocused)
                    .onSubmit { finalizeDocument() }
                    .disabled(engine.isSaving)
                Text(".pdf")
                    .foregroundStyle(.secondary)
                Button("Discard", role: .destructive) { discardScan() }
                    .disabled(engine.isBusy || engine.isSaving)
                    .help("Throw this scan away — the PDF moves to the Trash")
                Button("Done") { finalizeDocument() }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isBusy || engine.isSaving || engine.pages.isEmpty)
                    .help("Commit the name and finish — shows the saved PDF")
            }
            .font(.title3)

            // Always laid out, even when empty: the header must not jump as
            // work starts and finishes.
            HStack(spacing: 5) {
                if let activity = engine.activity {
                    ProgressView()
                        .controlSize(.small)
                    Text(activity)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 16, alignment: .leading)
            .padding(.leading, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Done: commit the typed name, finalize the document, and switch the
    /// view to the finished PDF.
    private func finalizeDocument() {
        engine.renameDocument(to: draftName)
        nameFieldFocused = false
        guard !engine.isBusy, !engine.pages.isEmpty else { return }
        let finishedURL = engine.documentURL
        engine.done()
        selection = finishedURL
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Ready to Scan")
                .font(.title2.weight(.semibold))
            Text(
                "Load paper, then press Scan here or the button on the scanner.\n"
                    + "PDFs are saved to \(engine.settings.destinationPath).\n"
                    + "Settings are in SnapScan ▸ Settings (⌘,)."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            if engine.feederWasEmpty {
                Label("The feeder was empty — load paper and try again.", systemImage: "tray")
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
            if let error = engine.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func pageCell(_ page: ScannedPage, number: Int, size: CGFloat) -> some View {
        let isSelected = selectedPages.contains(page.id)
        return VStack(spacing: 6) {
            Image(nsImage: page.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: size * 1.4)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: isSelected ? 3 : 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                // Found blank: it stays in view until its batch finishes, then
                // leaves for the count in the bottom bar.
                .opacity(page.isBlank ? 0.5 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if page.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(5)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(4)
                    } else if page.isBlank {
                        Text("Blank")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(4)
                    }
                }
                .onTapGesture(count: 2) { enlargedPage = page }
                .onTapGesture {
                    let commandHeld =
                        NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                    if commandHeld {
                        if isSelected {
                            selectedPages.remove(page.id)
                        } else {
                            selectedPages.insert(page.id)
                        }
                    } else {
                        selectedPages = [page.id]
                    }
                    gridFocused = true
                }
            Text("Page \(number)" + (page.snappedSizeName.map { " · \($0)" } ?? ""))
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contextMenu {
            Button("View Larger") { enlargedPage = page }
            Button(
                isSelected && selectedPages.count > 1
                    ? "Delete \(selectedPages.count) Pages" : "Delete Page",
                role: .destructive
            ) {
                if isSelected {
                    deleteSelectedPages()
                } else {
                    engine.deletePage(page)
                }
            }
        }
    }

    /// The page currently feeding through the scanner, growing as rows arrive.
    private func liveScanCell(size: CGFloat) -> some View {
        VStack(spacing: 6) {
            Group {
                if let live = engine.livePageImage {
                    Image(nsImage: NSImage(cgImage: live, size: .zero))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .aspectRatio(0.77, contentMode: .fit)
                        .overlay { ProgressView() }
                }
            }
            .frame(maxHeight: size * 1.4)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            if let fraction = engine.livePageFraction {
                ProgressView(value: fraction)
                    .controlSize(.small)
                    .frame(maxWidth: size * 0.8)
            } else {
                Text("Scanning…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pagePreview(_ page: ScannedPage) -> some View {
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: page.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 900, maxHeight: 1100)
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { enlargedPage = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 500, minHeight: 600)
    }

    private var bottomBar: some View {
        HStack {
            Text("\(engine.pages.count) page\(engine.pages.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            if let skipped = engine.current?.skippedBlankPages.count, skipped > 0 {
                Text("· \(skipped) blank page\(skipped == 1 ? "" : "s") skipped")
                    .foregroundStyle(.secondary)
                Button("Put Back") { engine.restoreSkippedBlankPages() }
                    .buttonStyle(.link)
                    .disabled(engine.isBusy)
                    .help("Return the skipped pages to where they were scanned")
            }
            if let error = engine.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(.bar)
    }

    // MARK: - Toolbar

    /// A setting as a binding, for the controls that change it directly.
    private func setting<Value>(_ key: WritableKeyPath<ScanSettings, Value>) -> Binding<Value> {
        Binding(
            get: { engine.settings[keyPath: key] },
            set: { engine.settings[keyPath: key] = $0 })
    }

    /// Auto always crops to the sheet, so under Auto the toggle shows on.
    private var cropBinding: Binding<Bool> {
        Binding(
            get: { engine.settings.autocrop || engine.settings.paperSize == .auto },
            set: { engine.settings.autocrop = $0 })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // What changes from one stack of paper to the next. The rest — and
        // these again — are in Settings. Fixed while a scan is running: the
        // scanner and each page's processing have already taken them.
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Paper", selection: setting(\.paperSize)) {
                ForEach(PaperSize.allCases) { size in
                    Text(size.rawValue).tag(size)
                }
            }
            .disabled(engine.isBusy)
            .help("Paper size")
            Picker("Sides", selection: setting(\.source)) {
                ForEach(ScanSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .disabled(engine.isBusy)
            .help("Which sides of each sheet to keep")
            Picker("Color", selection: setting(\.mode)) {
                ForEach(ScanMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .disabled(engine.isBusy)
            .help("Color, grayscale, or black & white")
            Picker("Resolution", selection: setting(\.resolution)) {
                ForEach(ScanSettings.resolutions, id: \.self) { dpi in
                    Text("\(dpi) dpi").tag(dpi)
                }
            }
            .disabled(engine.isBusy)
            .help("Resolution")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: cropBinding) {
                Label("Crop to Sheet", systemImage: "crop")
            }
            .disabled(engine.isBusy || engine.settings.paperSize == .auto)
            .help(
                engine.settings.paperSize == .auto
                    ? "Crop to the sheet — Auto paper size always does"
                    : "Crop each page to the sheet, for paper smaller than \(engine.settings.paperSize.rawValue)")
            Toggle(isOn: setting(\.skipBlankPages)) {
                Label("Skip Blank Pages", systemImage: "rectangle.portrait.slash")
            }
            .disabled(engine.isBusy)
            .help("Leave blank pages out of the PDF")
            Toggle(isOn: setting(\.appendScans)) {
                Label("Combine Scans", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(engine.isBusy)
            .help(
                "Add each scan to the open PDF until you press Done, "
                    + "rather than saving each as its own")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            scannerStatusIndicator
            if case .scanning = engine.status {
                Button {
                    engine.cancelScan()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await engine.scan() }
                } label: {
                    Label("Scan", systemImage: "scanner")
                }
                .disabled(engine.isBusy || !engine.scannerPresent)
            }
        }
    }

    private var scannerStatusIndicator: some View {
        Button {
            Task { await engine.detectScanner() }
        } label: {
            if !engine.scannerPresent {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            } else if engine.status == .detecting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .help(
            !engine.scannerPresent
                ? "Scanner not connected — plug in the scanner and open its feeder flap"
                : engine.status == .detecting
                    ? "Looking for scanner…"
                    : (engine.scannerName ?? "Scanner ready"))
    }
}

/// ⌦ and ⎋ for the page grid. The Edit menu answers ⌫ for it, since SwiftUI
/// won't keep the grid focused long enough to hear keys itself — but a menu
/// item only takes one key, and a bare ⎋ never reaches the menu, so this
/// listens for those two in the window instead.
private struct PageGridKeys: NSViewRepresentable {
    var canDelete: Bool
    var canDeselect: Bool
    var delete: () -> Void
    var deselect: () -> Void

    func makeNSView(context: Context) -> PageGridKeysView {
        let view = PageGridKeysView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PageGridKeysView, context: Context) {
        view.keys = self
    }
}

private final class PageGridKeysView: NSView {
    var keys: PageGridKeys?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let keys, event.window === window,
            event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
        else { return false }
        if event.specialKey == .deleteForward, keys.canDelete {
            keys.delete()
        } else if event.charactersIgnoringModifiers == "\u{1b}", keys.canDeselect {
            keys.deselect()
        } else {
            return false
        }
        return true
    }

    // Only here to listen; clicks belong to the grid.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
