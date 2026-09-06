//
//  NotificationScheduler.swift
//  Startline
//
//  명세서 9장 — 알림 3단계 + 롤링 스케줄러.
//
//  이 앱이 존재하는 이유는 "앱을 안 열어봐서 놓치는 것"을 막는 데 있다.
//  화면에 표시만 해서는 앱을 열어야 보이므로 아무것도 해결되지 않는다. (명세서 9.4)
//

import Foundation
import Observation
import SwiftData
import UserNotifications

// MARK: - 단계

/// 명세서 9.1 3단계.
enum StartStage: String, CaseIterable {
    /// 하루 전 — 정보.
    case advance
    /// 시작해야 하는 시점 — 행동 촉구.
    case start
    /// 시점이 지남 — 경고.
    case risk
}

/// 예약 대상 하나. 실제 등록 전 단계라 순수 값으로 다룬다.
nonisolated struct PlannedNotification: Equatable {
    let taskID: UUID
    let stage: StartStage
    let fireDate: Date
    let title: String
    let body: String

    var identifier: String { "startline|\(taskID.uuidString)|\(stage.rawValue)" }

    /// 알림 식별자에서 되찾는다. 앱이 꺼져 있다가 액션으로 깨어날 때 쓴다.
    static func parse(identifier: String) -> (taskID: UUID, stage: StartStage)? {
        let parts = identifier.split(separator: "|")
        guard parts.count == 3,
              parts[0] == "startline",
              let id = UUID(uuidString: String(parts[1])),
              let stage = StartStage(rawValue: String(parts[2]))
        else { return nil }
        return (id, stage)
    }
}

// MARK: - 스케줄러

@MainActor
@Observable
final class NotificationScheduler {

    /// 시스템 한도는 앱당 64개이고 **초과분은 에러 없이 조용히 폐기된다.**
    /// 4개를 남겨 다른 경로(미루기 등)가 쓸 자리를 둔다. (명세서 9.2)
    nonisolated static let scheduleLimit = 60

    nonisolated static let categoryID = "startline.task"
    nonisolated static let startNowAction = "startline.startNow"
    nonisolated static let snoozeAction = "startline.snooze30"

    /// 「시작」 시점이 지난 뒤 「위험」을 언제 알릴지.
    /// 명세서는 "경과"라고만 하므로 잠정값이다. (BL-031)
    nonisolated static let riskDelay: TimeInterval = 60 * 60

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// 실제로 예약된 개수.
    private(set) var scheduledCount = 0
    /// 예약 후보 전체 개수. 한도를 넘겼는지 확인하는 데 쓴다.
    private(set) var candidateCount = 0
    private(set) var lastScheduledAt: Date?

    private let center = UNUserNotificationCenter.current()

    var isLimited: Bool { candidateCount > Self.scheduleLimit }

    // MARK: - 권한

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            return granted
        } catch {
            await refreshAuthorization()
            return false
        }
    }

    /// 알림에 붙는 액션들을 등록한다. 앱 시작 때 한 번 부른다.
    func registerCategories() {
        let startNow = UNNotificationAction(
            identifier: Self.startNowAction,
            title: "지금 시작",
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: Self.snoozeAction,
            title: "30분 미루기",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [startNow, snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: - 롤링 예약 (명세서 9.2)

    /// 전체를 다시 계산해 가까운 것부터 한도만큼만 예약한다.
    ///
    /// 예약분을 통째로 지우고 다시 넣는다. 부분 갱신은 어느 것이 남아 있는지
    /// 추적해야 해서 실수가 끼어들기 쉽다. 개수가 60개뿐이라 통째로 하는 편이 안전하다.
    func reschedule(for tasks: [ResolvedTask], now: Date = Date()) async {
        await refreshAuthorization()
        guard authorization == .authorized || authorization == .provisional else {
            scheduledCount = 0
            candidateCount = 0
            return
        }

        let all = Self.plan(for: tasks, now: now, limit: .max)
        let selected = Array(all.prefix(Self.scheduleLimit))

        center.removeAllPendingNotificationRequests()

        var registered = 0
        for planned in selected {
            let content = UNMutableNotificationContent()
            content.title = planned.title
            content.body = planned.body
            content.sound = .default
            content.categoryIdentifier = Self.categoryID
            content.userInfo = ["taskID": planned.taskID.uuidString]

            let interval = planned.fireDate.timeIntervalSince(now)
            guard interval > 0 else { continue }

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: planned.identifier,
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
                registered += 1
            } catch {
                NSLog("[Startline] 알림 예약 실패 \(planned.identifier): \(error.localizedDescription)")
            }
        }

        candidateCount = all.count
        scheduledCount = registered
        lastScheduledAt = now

        NSLog("[Startline] 알림 예약 \(registered)개 / 후보 \(all.count)개 (한도 \(Self.scheduleLimit))")
    }

    /// 30분 뒤로 미룬다.
    func snooze(_ identifier: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 30 * 60, repeats: false)
        let request = UNNotificationRequest(
            identifier: identifier + "|snoozed",
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    /// 검증용 — 지정한 초 뒤에 한 번 울린다.
    func scheduleTestNotification(after seconds: TimeInterval = 60) async {
        let content = UNMutableNotificationContent()
        content.title = "지금 시작할 시간이에요"
        content.body = "‘알림 확인용’ 지금 시작해야 마감을 맞출 수 있어요"
        content.sound = .default
        content.categoryIdentifier = Self.categoryID

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(
            identifier: "startline.test.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
        NSLog("[Startline] 테스트 알림 \(Int(seconds))초 뒤 예약")
    }

    // MARK: - 예약 계획 (순수 함수)

    /// 알릴 것들을 시각 순으로 계산한다.
    ///
    /// 부수효과가 없어 알림 권한 없이도 검증할 수 있다. 그래서 액터 격리에서 빼 둔다.
    ///
    /// 제외 대상:
    /// - 이미 시작했거나 완료한 할 일 (「지금 시작」을 눌렀다면 더 조를 이유가 없다)
    /// - 시작 시점이 없는 할 일 (리드타임 없음, 소요시간 미입력)
    /// - 이미 지나간 시각 — 지난 시각은 예약해도 울리지 않는다
    nonisolated static func plan(
        for tasks: [ResolvedTask],
        now: Date = Date(),
        limit: Int = scheduleLimit,
        calendar: Calendar = .current
    ) -> [PlannedNotification] {
        var planned: [PlannedNotification] = []

        for resolved in tasks {
            let task = resolved.task

            // 완료·진행 중은 알리지 않는다.
            guard task.status == .notStarted else { continue }
            // 리드타임이 없으면 시작 시점 자체가 없다.
            guard let deadline = resolved.startDeadline else { continue }

            let title = task.title
            let context = resolved.parentTitle.map { " (\($0))" } ?? ""

            for stage in StartStage.allCases {
                guard let fireDate = fireDate(for: stage, deadline: deadline, calendar: calendar)
                else { continue }
                // 지난 시각은 예약해도 울리지 않는다.
                // 「시작」이 지났어도 「위험」이 아직 안 왔으면 그것만 남는다.
                guard fireDate > now else { continue }

                planned.append(
                    PlannedNotification(
                        taskID: task.id,
                        stage: stage,
                        fireDate: fireDate,
                        title: headline(for: stage),
                        body: message(for: stage, title: title, context: context, deadline: deadline)
                    )
                )
            }
        }

        planned.sort { lhs, rhs in
            if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
            return lhs.identifier < rhs.identifier
        }

        return limit == .max ? planned : Array(planned.prefix(limit))
    }

    nonisolated static func fireDate(
        for stage: StartStage,
        deadline: Date,
        calendar: Calendar = .current
    ) -> Date? {
        switch stage {
        case .advance:
            return calendar.date(byAdding: .day, value: -1, to: deadline)
        case .start:
            return deadline
        case .risk:
            return deadline.addingTimeInterval(riskDelay)
        }
    }

    // MARK: - 문구 (원칙 4 — "착수" 같은 내부 용어를 쓰지 않는다)

    nonisolated static func headline(for stage: StartStage) -> String {
        switch stage {
        case .advance: return "내일 시작할 일이 있어요"
        case .start: return "지금 시작할 시간이에요"
        case .risk: return "시작 시간이 지났어요"
        }
    }

    nonisolated static func message(
        for stage: StartStage,
        title: String,
        context: String,
        deadline: Date
    ) -> String {
        switch stage {
        case .advance:
            return "‘\(title)’\(context) — 내일 \(StartlineFormat.spokenDayTime(deadline))에 시작해야 해요"
        case .start:
            return "‘\(title)’\(context) 지금 시작해야 마감을 맞출 수 있어요"
        case .risk:
            return "‘\(title)’\(context) 아직 시작하지 않았어요. 일정을 다시 잡아볼까요?"
        }
    }
}
