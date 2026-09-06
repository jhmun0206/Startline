//
//  ContentView.swift
//  Startline
//
//  Created by 문정환 on 9/5/26.
//

import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var allTasks: [ManagedTask]

    @State private var manager = CalendarManager()
    @State private var saver = PersistenceReporter()
    /// 알림 액션 처리기와 같은 인스턴스를 쓴다.
    private var scheduler: NotificationScheduler { AppDelegate.scheduler }
    /// 그리드에서 클릭한 일정. 우측 패널이 편집 시트를 연다.
    @State private var eventToOpen: DayEvent?
    /// 그리드에서 더블클릭한 날짜. 우측 패널이 추가 시트를 연다.
    @State private var addOnDate: Date?
    /// 그리드에서 드래그로 고른 기간.
    @State private var addRange: ClosedRange<Date>?
    /// 그리드에서 클릭한 할 일.
    @State private var taskToOpen: ManagedTask?

    var body: some View {
        Group {
            switch manager.accessState {
            case .notDetermined:
                AccessRequestView(manager: manager)
            case .denied:
                AccessDeniedView()
            case .authorized:
                // 명세서 4.2 — 좌: 월간 그리드 / 우: 선택 날짜 상세
                HSplitView {
                    MonthGridView(
                        manager: manager,
                        onOpenEvent: { eventToOpen = $0 },
                        onAddOnDate: { addOnDate = $0 },
                        onAddRange: { addRange = $0...$1 },
                        onOpenTask: { taskToOpen = $0.task },
                        scheduler: scheduler
                    )
                    .frame(minWidth: 640, idealWidth: 1000)

                    DayDetailView(
                        manager: manager,
                        eventToOpen: $eventToOpen,
                        addOnDate: $addOnDate,
                        addRange: $addRange,
                        taskToOpen: $taskToOpen
                    )
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
                }
            }
        }
        .frame(minWidth: 1040, idealWidth: 1400, minHeight: 700, idealHeight: 940)
        .environment(saver)
        // 명세서 9.2 롤링 스케줄러 — 아래 시점마다 전체를 다시 계산해 예약한다.
        .task { await rescheduleNotifications() }
        .onChange(of: saver.revision) { _, _ in
            Task { await rescheduleNotifications() }
        }
        .onChange(of: manager.storeChangeToken) { _, _ in
            Task { await rescheduleNotifications() }
        }
        // 앱이 닫히거나 뒤로 물러날 때 미저장 변경을 마저 쓴다.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            saver.commit(modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            saver.commit(modelContext)
        }
        .alert("저장 문제", isPresented: saveErrorBinding) {
            Button("확인") { saver.clearError() }
        } message: {
            Text(saver.lastErrorMessage ?? "")
        }
    }

    /// 할 일 전체를 부모 일정까지 반영해 계산한 뒤 알림을 다시 깐다.
    private func rescheduleNotifications() async {
        let resolver = TaskResolver(manager: manager, now: Date())
        await scheduler.reschedule(for: resolver.resolve(allTasks))
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saver.lastErrorMessage != nil },
            set: { if !$0 { saver.clearError() } }
        )
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

            Text("등록된 일정을 읽어 무엇을 언제 시작해야 하는지 알려드려요.\n일정을 고치거나 밖으로 보내지 않습니다.")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: ManagedTask.self, inMemory: true)
        .environment(PersistenceReporter())
}
