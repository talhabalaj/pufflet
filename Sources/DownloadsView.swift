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
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Downloads").font(.title3.bold())
            if model.downloads.jobs.isEmpty { Text("Choose a game and press Install.").foregroundStyle(.secondary) }
            if let error = model.downloads.storageError { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.downloads.jobs) { job in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(job.name).font(.headline); Spacer(); Text(job.state.title).foregroundStyle(.secondary) }
                            if [.preparing, .installing, .paused].contains(job.state) {
                                let report = model.headless.persistentEnabled ? model.headless.installReports[job.id] ?? SteamHostReport() : model.headless.report
                                Text(report.fields["install-paused-playing"] == 1 ? "Downloads paused while playing" : job.state == .paused ? "Paused — existing files are kept" : model.headless.persistentEnabled ? (report.fields["install-verifying"] == 1 ? "Steam is verifying and restoring game files…" : report.installStatus) : model.headless.status)
                                    .font(.callout).foregroundStyle(.secondary)
                                if let work = report.installWork {
                                    ProgressView(value: Double(work.done), total: Double(work.total))
                                    Text("Steam work: \(ByteCountFormatter.string(fromByteCount: work.done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: work.total, countStyle: .file))")
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                } else { ProgressView().controlSize(.small) }
                                if model.headless.persistentEnabled {
                                    HStack {
                                        Button(job.state == .paused ? "Resume" : "Pause") { Task { await model.controlDownload(job.state == .paused ? "resume" : "pause", job: job) } }
                                            .disabled(job.state == .preparing)
                                        Button("Stop download") { Task { await model.controlDownload("cancel", job: job) } }
                                    }.disabled(model.isStoppingDownload)
                                } else {
                                    Button(model.isStoppingDownload ? "Stopping…" : "Stop download") { Task { await model.stopDownloads() } }
                                        .disabled(model.isStoppingDownload)
                                }
                            } else if job.state == .queued {
                                Button("Remove from queue") { model.downloads.removeQueued(job.id) }
                            } else if [.failed, .stopped, .interrupted].contains(job.state) {
                                if let error = job.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                                Button("Retry") { model.retryDownload(job) }.disabled(model.isStoppingDownload)
                            }
                        }
                        Divider()
                    }
                }
            }.frame(maxHeight: 360)
            Text("Steam manages the download and installation. Stopping keeps existing files; Retry asks Steam to check them and continue.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 410)
    }
}
