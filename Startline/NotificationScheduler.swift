//
//  NotificationScheduler.swift
//  Startline
//
//  할 일 알림 — 할 일당 하나, 마감 − 사용자가 고른 오프셋. + 롤링 스케줄러.
//  (docs/DESIGN_direction.md · BL-067)
//
//  이 앱이 존재하는 이유는 "앱을 안 열어봐서 놓치는 것"을 막는 데 있다.
//  화면에 표시만 해서는 앱을 열어야 보이므로 아무것도 해결되지 않는다. (명세서 9.4)
//

import Foundation
import Observation
import SwiftData
import UserNotifications

// MARK: - 예약 대상

/// 예약 대상 하나. 실제 등록 전 단계라 순수 값으로 다룬다.
///
/// **할 일당 알림은 하나다.** 예전에는 예고(−1일) / 착수 / 위험(+1시간) 3단계였다. (BL-067)
/// 예고는 사용자가 「1일 전」을 고르면 되고, 위험 단계는 개념이 틀려 철회했다(BL-031).
nonisolated struct PlannedNotification: Equatable {
    let taskID: UUID
    let fireDate: Date
    let title: String
    let body: String

    /// 식별자 꼬리. 형식 「startline|<할 일 ID>|start」는 예전과 같게 둔다.
    static let kind = "start"

    var identifier: String { "startline|\(taskID.uuidString)|\(Self.kind)" }

    /// 알림 식별자에서 할 일 ID 를 되찾는다. 앱이 꺼져 있다가 액션으로 깨어날 때 쓴다.
    ///
    /// **꼬리를 따지지 않는다.** 이미 알림 센터에 떠 있는 예전 단계 알림(`|advance`·`|risk`)과
    /// 「30분 미루기」로 다시 온 알림(`|start|snoozed`)에서도 버튼이 동작해야 한다.
    /// 예전에는 정확히 세 조각만 받아서, **미룬 알림에서 버튼을 누르면 아무 일도 일어나지 않았다.**
    static func taskID(from identifier: String) -> UUID? {
        let parts = identifier.split(separator: "|")
        guard parts.count >= 3, parts[0] == "startline" else { return nil }
        return UUID(uuidString: String(parts[1]))
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
    /// 알림에서 바로 끝냈다고 표시한다. 예전의 「지금 시작」(진행 중으로 바꾸던 것)을 대신한다. (BL-066)
    nonisolated static let completeAction = "startline.complete"
    nonisolated static let snoozeAction = "startline.snooze30"

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
        // 앞으로 띄우지 않는다. 버튼 하나로 끝내는 것이 이 버튼의 목적이다.
        let complete = UNNotificationAction(
            identifier: Self.completeAction,
            title: "완료",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: Self.snoozeAction,
            title: "30분 미루기",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [complete, snooze],
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
        content.title = Self.headline
        content.body = "‘알림 확인용’ — 마감 확인용"
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
    /// **알림 시각 = 마감 − 사용자가 고른 오프셋. 앱이 보정하지 않는다.** (BL-067)
    /// 예전에는 마감과 다른 날이면 그날 아침 9시로 옮겼다. 사용자가 고른 시각에 울리면 되므로
    /// 그 규칙(`notifyMoment`)을 걷어냈다.
    nonisolated static func plan(
        for tasks: [ResolvedTask],
        now: Date = Date(),
        limit: Int = scheduleLimit,
        calendar: Calendar = .current
    ) -> [PlannedNotification] {
        var planned: [PlannedNotification] = []

        for resolved in tasks {
            let task = resolved.task

            // 끝낸 것만 알리지 않는다. 손만 대 놓은 것(예전의 「진행 중」)도 미완료라 알린다. (BL-066)
            guard !task.isCompleted else { continue }
            // 「알림 없음」이면 시점 자체가 없다.
            guard let fireDate = resolved.startDeadline else { continue }
            // 지난 시각은 예약해도 울리지 않는다.
            guard fireDate > now else { continue }

            planned.append(
                PlannedNotification(
                    taskID: task.id,
                    fireDate: fireDate,
                    title: headline,
                    body: message(
                        title: task.title,
                        parentTitle: resolved.parentTitle,
                        effectiveDueAt: resolved.effectiveDueAt,
                        calendar: calendar
                    )
                )
            )
        }

        planned.sort { lhs, rhs in
            if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
            return lhs.identifier < rhs.identifier
        }

        return limit == .max ? planned : Array(planned.prefix(limit))
    }

    // MARK: - 문구 (원칙 4 — 내부 용어를 쓰지 않는다)

    nonisolated static let headline = "시작할 시간이에요"

    /// 「‘보고서 초안’ ([졸프] 전체 미팅) — 마감 10월 11일 (토) 저녁 7시」
    ///
    /// 예전 문구 「지금 시작해야 마감을 맞출 수 있어요」는 앱이 소요시간을 알고 계산했을 때의 말이다.
    /// 지금은 사용자가 고른 시점에 울릴 뿐이라 그 주장을 할 수 없다. **사실(마감)만 말한다.**
    /// 마감은 사용자가 입력한 값이라 그대로 적는다. (원칙 1)
    nonisolated static func message(
        title: String,
        parentTitle: String?,
        effectiveDueAt: Date?,
        calendar: Calendar = .current
    ) -> String {
        let context = parentTitle.map { " (\($0))" } ?? ""
        guard let effectiveDueAt else { return "‘\(title)’\(context)" }
        return "‘\(title)’\(context) — 마감 \(StartlineFormat.spokenDayTime(effectiveDueAt, calendar: calendar))"
    }
}
