//
//  NotificationCompletion.swift
//  Startline
//
//  알림의 「완료」·「30분 미루기」 버튼 처리. (BL-066 · BL-067 · BL-072)
//

import Foundation
import SwiftData

// MARK: - 알림 「완료」 처리

/// 알림 버튼으로 할 일을 끝낸다.
///
/// 앱 델리게이트 밖으로 뺀 이유 — 이 경로는 **앱이 꺼진 채 알림 버튼으로 깨어날 때** 돈다.
/// 그 상황을 손으로 재현하기 어려워, 같은 함수를 테스트 프로세스에서 부르고 `kill -9` 로
/// 죽여 정말 디스크까지 내려가는지 확인한다. (`Tests/run-link-tests.sh`)
enum NotificationCompletion {

    enum Outcome: Equatable {
        case completed(title: String)
        case notFound
        case saveFailed(String)
    }

    static func complete(identifier: String, in context: ModelContext, at date: Date = Date()) -> Outcome {
        guard let targetID = PlannedNotification.taskID(from: identifier) else { return .notFound }

        let descriptor = FetchDescriptor<ManagedTask>(predicate: #Predicate { $0.id == targetID })
        guard let task = try? context.fetch(descriptor).first else { return .notFound }

        task.markDone(at: date)
        do {
            // 지연 저장에 맡기지 않는다. 앱이 곧바로 다시 꺼질 수 있다.
            try context.save()
            return .completed(title: task.title)
        } catch {
            return .saveFailed(error.localizedDescription)
        }
    }
}

// MARK: - 알림 「30분 미루기」 처리

/// 알림을 30분 미룬다. **미룬 시각을 할 일에 저장한다.** (BL-072)
///
/// 예전에는 시스템에 알림 하나를 따로 넣기만 해서, 앱이 다시 예약하면서 예약분을 통째로
/// 지울 때 미룬 알림도 사라졌다. 이제 미룬 시각이 할 일에 남아 있어 다시 예약할 때 그대로 들어간다.
///
/// 마감을 넘겨 미루는 것도 막지 않는다. 사용자가 직접 누른 것이다. (원칙 1)
enum NotificationSnooze {

    static let interval: TimeInterval = 30 * 60

    /// - Returns: 다시 울릴 시각. 할 일을 못 찾았거나 저장에 실패하면 `nil`.
    static func snooze(identifier: String, in context: ModelContext, now: Date = Date()) -> Date? {
        guard let targetID = PlannedNotification.taskID(from: identifier) else { return nil }

        let descriptor = FetchDescriptor<ManagedTask>(predicate: #Predicate { $0.id == targetID })
        guard let task = try? context.fetch(descriptor).first else { return nil }

        let until = now.addingTimeInterval(interval)
        task.snoozedUntil = until
        do {
            try context.save()
            return until
        } catch {
            return nil
        }
    }
}
