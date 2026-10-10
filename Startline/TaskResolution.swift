//
//  TaskResolution.swift
//  Startline
//
//  부모 일정을 반영해 할 일의 마감·착수마감을 확정하는 계층. (명세서 4.2, 7장)
//
//  뷰는 `ManagedTask` 를 직접 계산에 쓰지 않고 여기서 나온 `ResolvedTask` 만 본다.
//  부모 일정 조회가 필요한 계산을 한곳에 모아, 화면 곳곳에서 EventKit을 때리지 않게 한다.
//

import EventKit
import Foundation
import SwiftData

/// 부모 일정까지 반영해 계산이 끝난 할 일.
nonisolated struct ResolvedTask: Identifiable {
    let task: ManagedTask
    /// 명세서 4.2의 실효마감.
    let effectiveDueAt: Date?
    let startDeadline: Date?
    let judgment: StartJudgment?
    /// 부모 일정 제목. 독립 할 일이면 `nil`.
    let parentTitle: String?
    /// 찾아낸 부모 일정의 시작시각. 반복 일정에서 회차를 가르는 데 쓴다.
    var parentStart: Date?

    /// 부모 일정의 **회차**를 특정하는 키.
    /// 반복 일정은 회차마다 다르므로, 같은 일정의 다른 회차와 섞이지 않는다.
    var parentOccurrenceKey: String? {
        guard let parentEventID = task.parentEventID, let parentStart else { return nil }
        return DayEvent.occurrenceKey(eventID: parentEventID, start: parentStart)
    }

    var id: UUID { task.id }
    var isAttached: Bool { task.isAttached }

    // MARK: - 목록 순서

    /// 할 일 목록의 순서. **우측 패널과 그리드가 같은 이 규칙을 쓴다.**
    ///
    /// 미완료 먼저, 완료는 아래. 각 그룹 안에서는 마감이 빠른 순, 같으면 제목 순.
    /// 예전에는 시작 시점 순으로만 줄 세워 완료한 할 일이 미완료 사이에 섞였다.
    ///
    /// - Parameter isCompleted: 순서를 정할 때 쓸 완료 여부. 우측 패널은 체크 직후 1초 동안
    ///   **이전 값**을 넘겨 자리를 붙잡아 둔다. 잘못 눌렀을 때 바로 되돌릴 수 있게.
    static func listOrder(
        _ lhs: ResolvedTask,
        _ rhs: ResolvedTask,
        isCompleted: (ResolvedTask) -> Bool = { $0.task.isCompleted }
    ) -> Bool {
        let l = isCompleted(lhs), r = isCompleted(rhs)
        if l != r { return !l }
        let ld = lhs.effectiveDueAt ?? .distantFuture
        let rd = rhs.effectiveDueAt ?? .distantFuture
        if ld != rd { return ld < rd }
        return lhs.task.title < rhs.task.title
    }

    // MARK: - 「위험」과 「놓침」 (명세서 9.4)

    // 같은 데이터를 두 곳에서 다르게 판정하면 언젠가 어긋난다. 실제로 그리드와 우측 패널이
    // 서로 다른 비교자를 써서 정렬이 어긋난 적이 있다. 그래서 판정식을 여기 하나로 모은다.
    //
    //   위험 = 시작할 때가 지났는데 아직 손대지 않음   → 배너 + 그리드 막대 + 알림
    //   놓침 = 마감까지 지났는데 아직 끝내지 않음      → 「기한 지난 할 일」 섹션
    //
    // **두 집합은 겹치지 않는다.** 마감까지 지난 일은 「오늘 시작할 일」이 아니다.

    /// 마감까지 지났는데 아직 끝내지 않았다. (명세서 9.4 「놓침」)
    ///
    /// 완료 여부만 본다. 시작했든 안 했든 마감이 지났으면 놓친 것이다.
    func isMissed(now: Date) -> Bool {
        guard !task.isCompleted else { return false }
        guard let effectiveDueAt else { return false }
        return effectiveDueAt < now
    }

    /// 시작할 때가 지났는데 아직 끝내지 않았다. (명세서 9.4 「위험」)
    ///
    /// **마감까지 지났으면 위험이 아니라 놓침이다.** 그쪽이 맡는다.
    func isAtRisk(now: Date) -> Bool {
        guard !task.isCompleted else { return false }
        guard let startDeadline, startDeadline < now else { return false }
        return !isMissed(now: now)
    }

    /// 배너가 세는 「오늘 몫」. (명세서 5.2)
    ///
    /// 오늘이 시작하는 날이거나, 시작할 때를 이미 놓친 것.
    /// 완료한 것도 들어온다 — 「원래 있었는데 다 했다」와 「원래 없었다」를 가르기 위해서다.
    ///
    /// 마감까지 지난 일은 빼낸다. 그것을 「오늘 시작할 일」로 세는 것은 말이 안 된다.
    func isTodaysStart(now: Date, calendar: Calendar) -> Bool {
        guard let startDeadline else { return false }
        if isMissed(now: now) { return false }
        if calendar.isDate(startDeadline, inSameDayAs: now) { return true }
        return isAtRisk(now: now)
    }

    /// "회의 장소 연락 → GDG 미팅" — 부모가 있으면 맥락을 함께 보여준다. (명세서 5.2)
    var contextualTitle: String {
        guard let parentTitle else { return task.title }
        return "\(task.title) → \(parentTitle)"
    }
}

/// 할 일을 부모 일정과 맞춰 계산해 주는 도구.
struct TaskResolver {
    let manager: CalendarManager
    let now: Date

    func resolve(_ task: ManagedTask) -> ResolvedTask {
        let parent = parentEvent(for: task)
        let effectiveDueAt = task.effectiveDueAt(parentStart: parent?.startDate)

        return ResolvedTask(
            task: task,
            effectiveDueAt: effectiveDueAt,
            startDeadline: task.startDeadline(
                effectiveDueAt: effectiveDueAt,
                calendar: manager.calendar
            ),
            judgment: task.judgment(
                effectiveDueAt: effectiveDueAt,
                now: now,
                calendar: manager.calendar
            ),
            parentTitle: parent?.title,
            parentStart: parent?.startDate
        )
    }

    func resolve(_ tasks: [ManagedTask]) -> [ResolvedTask] {
        tasks.map(resolve)
    }

    private func parentEvent(for task: ManagedTask) -> EKEvent? {
        guard let parentEventID = task.parentEventID else { return nil }
        return manager.parentEvent(id: parentEventID, occurrenceDate: task.parentOccurrenceDate)
    }
}

// MARK: - 저장값 정리

/// 부모 일정이 사라져 독립 할 일로 전환된 사실. 사용자에게 알릴 내용. (명세서 4.2)
struct DetachedTaskNotice: Identifiable {
    let id: UUID
    /// 어떤 할 일이 전환됐는지.
    let title: String
    /// 어떤 마감으로 확정됐는지. 전환 시점에 마감을 알 수 없었으면 `nil`.
    let confirmedDueAt: Date?

    /// "회의 장소 연락 — 9월 19일 (토) 저녁 7시까지"
    var summary: String {
        guard let confirmedDueAt else { return "\(title) — 마감 없음" }
        return "\(title) — \(StartlineFormat.spokenDayTime(confirmedDueAt))까지"
    }
}

/// 부모 일정 상태를 저장값에 반영한다.
///
/// **화면을 그리는 도중이 아니라 명시적인 시점에만 호출한다.**
/// (화면 진입, 월 이동, 외부 캘린더 변경 감지) 뷰 본문에서 저장을 일으키지 않기 위해서다.
enum TaskLinkMaintenance {

    /// 부모 일정 상태를 저장값에 반영한다.
    ///
    /// **부모를 못 찾아도 연결을 끊지 않는다.** 알리기만 한다. (BL-045)
    /// 부모가 옮겨졌으면 실효마감 사본을 갱신해, 나중에 부모가 삭제될 때 승격시킬 값을 확보한다.
    /// (명세서 4.2)
    ///
    /// EventKit에 직접 의존하지 않도록 부모 조회를 인자로 받는다. 덕분에 캘린더 권한 없이도
    /// 이 로직을 검증할 수 있다.
    ///
    /// - Parameter parentStart: 할 일의 부모 일정 시작시각을 돌려준다. 삭제됐으면 `nil`.
    /// - Returns: 이번에 전환된 항목들. 사용자에게 알릴 대상.
    @discardableResult
    static func sync(
        tasks: [ManagedTask],
        parentStart: (ManagedTask) -> Date?
    ) -> [DetachedTaskNotice] {
        var notices: [DetachedTaskNotice] = []

        for task in tasks where task.isAttached {
            guard let start = parentStart(task) else {
                // 부모를 못 찾았다. **여기서 연결을 끊지 않는다.**
                //
                // 조회 실패가 곧 삭제는 아니다. 계정 동기화 중이거나 식별자가 바뀌는 등
                // 잠깐 못 찾는 경우가 있는데, 그때 연결을 지우면 되돌릴 방법이 없다.
                // 실제로 이 자동 전환이 멀쩡한 연결을 지운 사례가 나왔다. (BL-045)
                //
                // 마감은 마지막으로 확정된 `dueAt` 으로 물러서므로 화면은 정상 동작한다.
                // 끊을지는 사용자가 「특정 날짜」를 골라 정한다.
                notices.append(
                    DetachedTaskNotice(id: task.id, title: task.title, confirmedDueAt: task.dueAt)
                )
                continue
            }

            // 부모가 옮겨졌으면 실효마감도 함께 옮겨진다. 그 값을 사본으로 남긴다.
            if let offset = task.offsetFromParent {
                let effective = start.addingTimeInterval(offset)
                if task.dueAt != effective {
                    task.dueAt = effective
                }
            }
        }

        return notices
    }

    /// EventKit에서 부모를 조회하는 실제 경로.
    @discardableResult
    static func sync(
        tasks: [ManagedTask],
        manager: CalendarManager
    ) -> [DetachedTaskNotice] {
        guard manager.accessState == .authorized else { return [] }

        return sync(tasks: tasks) { task in
            guard let parentEventID = task.parentEventID else { return nil }
            return manager.parentEvent(
                id: parentEventID,
                occurrenceDate: task.parentOccurrenceDate
            )?.startDate
        }
    }
}
