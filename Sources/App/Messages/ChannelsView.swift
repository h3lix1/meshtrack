// ChannelsView — the monitor-only Channels screen (ADR 0006): a bespoke
// chat-style layout (no stock List, for snapshot fidelity) with a channel
// sidebar and a transcript pane. Renders ChannelsViewModel read-only: sender
// short-names, @mention highlighting, timestamps, and DM vs broadcast badges.
// There is no compose/send affordance — monitoring only.

import Domain
import Foundation
import SwiftUI

public struct ChannelsView: View {
    @State private var viewModel: ChannelsViewModel

    public init(viewModel: ChannelsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        HStack(spacing: 0) {
            channelList
                .frame(width: 230)
            Divider().overlay(Color.white.opacity(0.08))
            transcript
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            try? await viewModel.load()
        }
    }

    // MARK: Channel sidebar

    private var channelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CHANNELS")
                .font(.system(size: 10, weight: .bold)).tracking(2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(viewModel.channels) { channel in
                        channelRow(channel)
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
        }
    }

    private func channelRow(_ channel: ChannelSummary) -> some View {
        let isSelected = viewModel.selectedSummary?.channel == channel.channel
        return Button {
            viewModel.select(channel.channel)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: channel.isUnnamed ? "number" : "number.square.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(channel.isUnnamed ? Color.secondary : Color.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(channel.messageCount) msg")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.cyan.opacity(0.16) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcript: some View {
        if let channel = viewModel.selectedSummary {
            VStack(alignment: .leading, spacing: 0) {
                transcriptHeader(channel)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(channel.messages) { message in
                            messageRow(message)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 32)).foregroundStyle(.secondary)
                Text("No messages decoded yet")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func transcriptHeader(_ channel: ChannelSummary) -> some View {
        HStack(spacing: 8) {
            Text(channel.name)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(.white)
            Text("READ-ONLY")
                .font(.system(size: 9, weight: .bold)).tracking(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            Text("\(channel.messageCount) messages")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func messageRow(_ message: MessageDisplay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(message.sender)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.cyan)
                if message.isDirectMessage {
                    badge("DM", .purple)
                } else {
                    badge("BROADCAST", .secondary)
                }
                Text(Self.timeFormatter.string(from: message.rxTime.date))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            body(message)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func body(_ message: MessageDisplay) -> some View {
        Text(Self.attributedBody(message))
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Build a styled body string: plain runs dimmed white, `@mention` runs
    /// highlighted yellow + semibold.
    nonisolated static func attributedBody(_ message: MessageDisplay) -> AttributedString {
        var result = AttributedString()
        for segment in message.segments {
            var run = AttributedString(segment.text)
            switch segment.kind {
            case .text:
                run.foregroundColor = .white.opacity(0.9)
            case .mention:
                run.foregroundColor = .yellow
                run.font = .system(size: 13, weight: .semibold)
            }
            result.append(run)
        }
        return result
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold)).tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))
            )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private extension Instant {
    /// Wall-clock `Date` for display formatting (presentation layer only).
    var date: Date {
        Date(timeIntervalSince1970: Double(nanosecondsSinceEpoch) / 1_000_000_000)
    }
}
