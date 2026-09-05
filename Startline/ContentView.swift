//
//  ContentView.swift
//  Startline
//
//  Created by 문정환 on 9/5/26.
//

import EventKit
import SwiftUI

struct ContentView: View {
    @State private var manager = CalendarManager()

    var body: some View {
        Group {
            switch manager.accessState {
            case .notDetermined:
                AccessRequestView(manager: manager)
            case .denied:
                AccessDeniedView()
            case .authorized:
                CalendarContentView(manager: manager)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

// MARK: - 권한 미결정

/// 시스템 권한 팝업 이전에 이유를 먼저 설명하는 사전 안내 화면. (명세서 3.1)
private struct AccessRequestView: View {
    let manager: CalendarManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("캘린더 접근이 필요합니다")
                .font(.title2.bold())

            Text("등록된 일정의 마감시각을 읽어 착수일을 역산합니다.\n일정을 수정하거나 외부로 전송하지 않습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("캘린더 접근 요청") {
                Task { await manager.requestAccess() }
            }
            .keyboardShortcut(.defaultAction)

            if let errorMessage = manager.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(40)
    }
}

// MARK: - 권한 거부

private struct AccessDeniedView: View {
    @Environment(\.openURL) private var openURL

    private let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("캘린더 접근이 거부되어 있습니다")
                .font(.title2.bold())

            Text("시스템 설정 → 개인정보 보호 및 보안 → 캘린더에서\nStartline을 허용한 뒤 앱을 다시 실행해 주세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let settingsURL {
                Button("시스템 설정 열기") { openURL(settingsURL) }
            }
        }
        .padding(40)
    }
}

// MARK: - 권한 승인

private struct CalendarContentView: View {
    let manager: CalendarManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CalendarSourceListView(calendars: manager.calendars)

            Divider()

            HStack {
                Text(Self.monthTitle)
                    .font(.headline)
                Spacer()
                Text("일정 \(manager.events.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    manager.loadCalendarsAndEvents()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("다시 불러오기")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if manager.events.isEmpty {
                VStack {
                    Spacer()
                    Text("이번 달 일정이 없습니다.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(Array(manager.events.enumerated()), id: \.offset) { _, event in
                        EventRow(event: event)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private static var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: Date())
    }
}

/// 접근 가능한 전체 캘린더 목록 — 이름 + 소속 소스명.
private struct CalendarSourceListView: View {
    let calendars: [EKCalendar]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("접근 가능한 캘린더 (\(calendars.count))")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if calendars.isEmpty {
                Text("등록된 캘린더가 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(calendars, id: \.calendarIdentifier) { calendar in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(cgColor: calendar.cgColor))
                                    .frame(width: 8, height: 8)
                                Text(calendar.title)
                                    .font(.caption)
                                Text(calendar.source.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(16)
    }
}

/// 일정 한 행 — [시작시각] [제목] [소속 캘린더명]
private struct EventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(startText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            Text(event.title ?? "(제목 없음)")
                .font(.body)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                if let cgColor = event.calendar?.cgColor {
                    Circle()
                        .fill(Color(cgColor: cgColor))
                        .frame(width: 8, height: 8)
                }
                Text(event.calendar?.title ?? "(캘린더 없음)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var startText: String {
        guard let startDate = event.startDate else { return "-" }
        if event.isAllDay {
            return Self.dayFormatter.string(from: startDate) + " 종일"
        }
        return Self.dateTimeFormatter.string(from: startDate)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.setLocalizedDateFormatFromTemplate("MdE HHmm")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.setLocalizedDateFormatFromTemplate("MdE")
        return formatter
    }()
}

#Preview {
    ContentView()
}
