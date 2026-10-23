import AppKit
import SwiftUI

nonisolated extension GameDownload.State {
    var title: String {
        switch self {
        case .queued: "Queued"
        case .preparing: "Preparing…"
        case .installing: "Installing…"
        case .paused: "Paused"
        case .completed: "Installed"
        case .failed: "Needs attention"
        case .stopped: "Stopped"
        case .interrupted: "Interrupted"
        }
    }
}

struct DownloadsView: View {
    @Bindable var model: LibraryModel
    private let rowHeight: CGFloat = 60

    /// Steam's queue, then Epic's.
    private var jobs: [GameDownload] { model.downloads.jobs + model.epicDownloads.jobs }

    var body: some View {
        let updates = model.updatableGames, jobs = jobs
        if jobs.isEmpty && updates.isEmpty {
            ContentUnavailableView {
                Label("No Downloads", systemImage: "arrow.down.circle")
            } description: {
                Text("Games you install appear here.")
            } actions: {
                checkButton
            }
            .frame(width: 340, height: 220)
        } else {
            VStack(spacing: 0) {
                if let error = model.downloads.storageError ?? model.epicDownloads.queue.storageError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    Divider()
                }
                if !jobs.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(jobs) { job in
                                DownloadRow(job: job, model: model).frame(height: rowHeight)
                                if job.id != jobs.last?.id { Divider().padding(.leading, 56) }
                            }
                        }
                    }
                    // Rows have a fixed height, so the list is as tall as its rows (up to five) instead of collapsing in the popover.
                    .frame(height: CGFloat(min(jobs.count, 5)) * (rowHeight + 1))
                    Divider()
                }
                HStack {
                    Text(summary(updates: updates.count)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if updates.isEmpty {
                        checkButton
                    } else {
                        Button("Update All") { model.updateAll() }
                            .help("Download Steam updates for " + ListFormatter.localizedString(byJoining: updates.map(\.name)))
                    }
                    Button("Clear") { model.downloads.clearFinished(); model.epicDownloads.queue.clearFinished() }
                        .disabled(!model.downloads.hasFinished && !model.epicDownloads.queue.hasFinished)
                        .help("Remove finished and stopped downloads from this list")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(width: 380)
        }
    }

    private var checkButton: some View {
        Button("Check for Updates") { Task { await model.checkForGameUpdates() } }
            .disabled(model.isCheckingForUpdates || model.ownedLibrary.isRefreshing)
            .help("Ask Steam whether your installed games have updates")
    }

    private func summary(updates: Int) -> String {
        let pending = jobs.filter { [.queued, .preparing, .installing, .paused].contains($0.state) }.count
        if pending > 0 { return pending == 1 ? "1 download in progress or waiting" : "\(pending) downloads in progress or waiting" }
        if updates > 0 { return updates == 1 ? "1 game has an update" : "\(updates) games have updates" }
        return "No downloads in progress"
    }
}

private struct DownloadRow: View {
    let job: GameDownload
    @Bindable var model: LibraryModel
    @State private var artwork: NSImage?

    private var isActive: Bool { [.preparing, .installing, .paused].contains(job.state) }
    private var isEpic: Bool { GameID(job.id)?.store == .epic }
    private var report: SteamHostReport {
        model.headless.persistentEnabled ? model.headless.installReports[job.id] ?? SteamHostReport() : model.headless.report
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let artwork { Image(nsImage: artwork).resizable().scaledToFill() } else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 30, height: 44).clipShape(.rect(cornerRadius: 4))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).lineLimit(1)
                if isActive {
                    if let work = isEpic ? model.epicDownloads.fraction(for: job.id) : report.installWork {
                        ProgressView(value: Double(work.done), total: Double(work.total)).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
                subtitle.font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) { actions }
                .buttonStyle(.borderless).labelStyle(.iconOnly).imageScale(.large).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .task(id: job.id) { artwork = await model.artwork(for: job.id, kind: .cover) }
    }

    @ViewBuilder private var subtitle: some View {
        switch job.state {
        case .preparing, .installing, .paused:
            Text(model.downloadActivityStatus(for: job))
        case .queued: Text(job.kind == .update ? "Waiting to update" : "Waiting")
        case .completed: Text(model.downloadStatus(for: job.id) ?? job.state.title)
        case .failed, .stopped, .interrupted:
            if let error = job.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).help(error)
            } else { Text(job.state.title) }
        }
    }

    @ViewBuilder private var actions: some View {
        if isEpic { epicActions } else { steamActions }
    }

    /// Epic downloads run in Pufflet itself: pausing keeps verified files, and
    /// Resume or Retry only downloads what is missing.
    @ViewBuilder private var epicActions: some View {
        switch job.state {
        case .preparing, .installing, .paused:
            Button(job.state == .paused ? "Resume" : "Pause", systemImage: job.state == .paused ? "play.circle.fill" : "pause.circle.fill") {
                if job.state == .paused { model.epicDownloads.resume(job.id) } else { model.epicDownloads.pause(job.id) }
            }
            .help(job.state == .paused ? "Resume download" : "Pause download")
            .disabled(job.state == .preparing)
            Button("Stop", systemImage: "xmark.circle.fill") { model.epicDownloads.cancel(job.id) }
                .help("Stop download. Downloaded files are kept, and Retry continues from them.")
        case .queued:
            Button("Remove from Queue", systemImage: "xmark.circle.fill") { model.epicDownloads.queue.removeQueued(job.id) }
                .help("Remove from queue")
        case .failed, .stopped, .interrupted:
            Button("Retry", systemImage: "arrow.clockwise.circle.fill") { model.epicDownloads.resume(job.id) }
                .help("Retry. Pufflet checks the existing files and downloads only what’s missing.")
        case .completed:
            if let entry = model.entries.first(where: { $0.id == job.id }), let folder = model.epicFolder(entry) {
                Button("Show in Finder", systemImage: "magnifyingglass.circle.fill") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                }
                .help("Show in Finder")
            }
        }
    }

    @ViewBuilder private var steamActions: some View {
        switch job.state {
        case .preparing, .installing, .paused:
            if model.headless.persistentEnabled {
                Button(job.state == .paused ? "Resume" : "Pause", systemImage: job.state == .paused ? "play.circle.fill" : "pause.circle.fill") {
                    Task { await model.controlDownload(job.state == .paused ? "resume" : "pause", job: job) }
                }
                .help(job.state == .paused ? "Resume download" : "Pause download")
                .disabled(job.state == .preparing || model.isStoppingDownload)
                Button("Stop", systemImage: "xmark.circle.fill") { Task { await model.controlDownload("cancel", job: job) } }
                    .help("Stop download. Existing files are kept, and Retry continues from them.")
                    .disabled(model.isStoppingDownload)
            } else {
                Button("Stop", systemImage: "xmark.circle.fill") { Task { await model.stopDownloads() } }
                    .help("Stop download. Existing files are kept, and Retry continues from them.")
                    .disabled(model.isStoppingDownload)
            }
        case .queued:
            Button("Remove from Queue", systemImage: "xmark.circle.fill") { model.downloads.removeQueued(job.id) }
                .help("Remove from queue")
        case .failed, .stopped, .interrupted:
            Button("Retry", systemImage: "arrow.clockwise.circle.fill") { model.retryDownload(job) }
                .help("Retry. Steam checks the existing files and continues.")
                .disabled(!model.canRetryDownload(job))
        case .completed:
            if let game = model.games.first(where: { $0.id == job.id }) {
                Button("Show in Finder", systemImage: "magnifyingglass.circle.fill") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: game.folder.path)
                }
                .help("Show in Finder")
            }
        }
    }
}
