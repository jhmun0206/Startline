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

/// 부모 일정 상태를 저장값에 반영한다.
///
/// **화면을 그리는 도중이 아니라 명시적인 시점에만 호출한다.**
/// (화면 진입, 월 이동, 새로고침, 주기 갱신) 뷰 본문에서 저장을 일으키지 않기 위해서다.
enum TaskLinkMaintenance {

    /// 부모 일정이 삭제된 할 일을 독립 할 일로 전환한다.
    ///
    /// 할 일을 함께 지우지 않는다. 마지막으로 계산된 실효마감을 확정 마감으로 승격시킨다.
    /// (명세서 4.2)
    ///
    /// - Returns: 이번에 전환된 할 일의 제목들. 사용자에게 알릴 대상.
    @discardableResult
    static func sync(
        tasks: [ManagedTask],
        manager: CalendarManager,
        now: Date = Date()
    ) -> [String] {
        guard manager.accessState == .authorized else { return [] }

        var detachedTitles: [String] = []

        for task in tasks where task.isAttached {
            guard let parentEventID = task.parentEventID else { continue }

            let parent = manager.parentEvent(
                id: parentEventID,
                occurrenceDate: task.parentOccurrenceDate
            )

            guard let parentStart = parent?.startDate else {
                // 부모가 사라졌다. 마지막으로 확정된 마감을 유지한 채 독립 할 일로 전환한다.
                task.detachFromParent(lastKnownDueAt: task.dueAt)
                detachedTitles.append(task.title)
                continue
            }

            // 부모가 옮겨졌으면 실효마감도 함께 옮겨진다. 그 값을 사본으로 남겨,
            // 나중에 부모가 삭제됐을 때 승격시킬 값을 확보해 둔다.
            if let offset = task.offsetFromParent {
                let effective = parentStart.addingTimeInterval(offset)
                if task.dueAt != effective {
                    task.dueAt = effective
                }
            }
        }

        return detachedTitles
    }
}
