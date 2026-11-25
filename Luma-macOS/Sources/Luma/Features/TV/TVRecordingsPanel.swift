import SwiftUI

/// 夜航页底部的录制中心：定时录制、录制中、已完成，以及「追剧录」入口。
/// 数据与录制任务都在 `IPTVBrowserModel` 里，视图只负责展示与触发。
struct TVRecordingsPanel: View {
    @EnvironmentObject private var tv: IPTVBrowserModel

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if tv.recordings.isEmpty {
                emptyHint
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(tv.recordings) { recording in
                        recordingRow(recording)
                    }
                }
            }
            if !tv.subscriptions.isEmpty {
                seriesSection
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "record.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TVBrand.signal)
                Text("录制中心")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(tv.pendingRecordings.count) 个等待 · \(tv.finishedRecordings.count) 个已结束")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if tv.finishedRecordings.contains(where: { $0.state != .recording }) {
                Button("清理已结束") {
                    for recording in tv.finishedRecordings {
                        tv.removeRecording(recording)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 10.5))
            }
        }
    }

    private var emptyHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 12))
            Text("还没有录制。在赛事或节目上右键，选「定时录制」就开始排队。")
                .font(.system(size: 11.5))
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .background(TVBrand.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func recordingRow(_ recording: TVRecording) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: recording.state))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint(for: recording.state))
                .frame(width: 26, height: 26)
                .background(tint(for: recording.state).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(recording.channelName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(timeText(recording))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(stateText(recording))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(tint(for: recording.state))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tint(for: recording.state).opacity(0.12),
                                    in: Capsule(style: .continuous))
                    if let note = recording.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            if recording.state == .scheduled {
                Button("取消") { tv.cancelRecording(recording) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
            } else if recording.state != .recording {
                Button("移除") { tv.removeRecording(recording) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(TVBrand.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.6)
        }
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "repeat.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TVBrand.wave)
                Text("追剧录")
                    .font(.system(size: 12, weight: .semibold))
                Text("给已追的节目录下一场播出")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            CatalogFlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(tv.subscriptions) { subscription in
                    Button {
                        tv.scheduleSeriesRecording(for: subscription)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(subscription.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(TVBrand.wave)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(TVBrand.wave.opacity(0.10), in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(TVBrand.wave.opacity(0.28), lineWidth: 0.6))
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("录制《\(subscription.title)》的下一场播出")
                }
            }
        }
    }

    private func symbol(for state: TVRecording.State) -> String {
        switch state {
        case .scheduled: return "clock"
        case .recording: return "record.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func tint(for state: TVRecording.State) -> Color {
        switch state {
        case .scheduled: return TVBrand.gold
        case .recording: return TVBrand.signal
        case .finished: return LumaBrand.mint
        case .failed: return TVBrand.danger
        case .cancelled: return .secondary
        }
    }

    private func stateText(_ recording: TVRecording) -> String {
        switch recording.state {
        case .scheduled: return "等待录制"
        case .recording: return "录制中"
        case .finished: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    private func timeText(_ recording: TVRecording) -> String {
        let sameDay = Calendar.current.isDateInToday(recording.start)
        let start = sameDay
            ? Self.clock.string(from: recording.start)
            : Self.dayClock.string(from: recording.start)
        let end = Self.clock.string(from: recording.end)
        return "\(start)–\(end)"
    }
}
