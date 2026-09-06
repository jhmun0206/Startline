//
//  NotificationStatusView.swift
//  Startline
//
//  알림 상태를 보고 확인하는 자리.
//  거부 상태를 앱 안에서 알 수 있어야 하고(명세서 9 요구), 예약 개수도 여기서 본다.
//

import SwiftUI
import UserNotifications

struct NotificationStatusView: View {
    let scheduler: NotificationScheduler

    @Environment(\.openURL) private var openURL

    private let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.notifications"
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("알림")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            switch scheduler.authorization {
            case .notDetermined:
                Text("시작할 시간이 되면 알려드릴까요?")
                    .font(.callout)
                Text("앱을 열어두지 않아도 제때 알려드려요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("알림 켜기") {
                    Task { await scheduler.requestAuthorization() }
                }

            case .denied:
                Label("알림이 꺼져 있어요", systemImage: "bell.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Text("알림이 없으면 앱을 열어봐야만 시작 시간을 알 수 있어요.\n시스템 설정 → 알림 → Startline에서 켜주세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let settingsURL {
                    Button("시스템 설정 열기") { openURL(settingsURL) }
                }

            default:
                Label("알림이 켜져 있어요", systemImage: "bell.badge")
                    .font(.callout)
                    .foregroundStyle(.green)

                Divider()

                LabeledContent("예약됨") {
                    Text("\(scheduler.scheduledCount)개")
                        .font(.system(.callout, design: .monospaced))
                }
                LabeledContent("전체 후보") {
                    Text("\(scheduler.candidateCount)개")
                        .font(.system(.callout, design: .monospaced))
                }

                if scheduler.isLimited {
                    Text("한도(\(NotificationScheduler.scheduleLimit)개)를 넘어, 가장 가까운 것부터 예약했어요.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let lastScheduledAt = scheduler.lastScheduledAt {
                    Text("마지막 정리 \(StartlineFormat.spokenDayTime(lastScheduledAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Button("1분 뒤 테스트 알림") {
                    Task { await scheduler.scheduleTestNotification(after: 60) }
                }
                .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .task { await scheduler.refreshAuthorization() }
    }
}
