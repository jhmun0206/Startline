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
struct ResolvedTask: Identifiable {
    let task: ManagedTask
    /// 명세서 4.2의 실효마감.
    let effectiveDueAt: Date?
    let startDeadline: Date?
    let judgment: StartJudgment?
    /// 부모 일정 제목. 독립 할 일이면 `nil`.
    let parentTitle: String?

    var id: UUID { task.id }
    var isAttached: Bool { task.isAttached }

    /// 「오늘 착수」에 들어갈 항목인지. (명세서 5.2)
    var needsStartAttention: Bool {
        switch judgment {
        case .startToday, .overdue: return true
        case .relaxed, nil: return false
        }
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
            parentTitle: parent?.title
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

    /// 부모 일정이 삭제된 할 일을 독립 할 일로 전환한다.
    ///
    /// 할 일을 함께 지우지 않는다. 마지막으로 계산된 실효마감을 확정 마감으로 승격시킨다.
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
                // 부모가 사라졌다. 마지막으로 확정된 마감을 유지한 채 독립 할 일로 전환한다.
                let confirmed = task.dueAt
                task.detachFromParent(lastKnownDueAt: confirmed)
                notices.append(
                    DetachedTaskNotice(id: task.id, title: task.title, confirmedDueAt: confirmed)
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
