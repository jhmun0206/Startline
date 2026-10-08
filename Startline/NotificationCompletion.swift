//
//  NotificationCompletion.swift
//  Startline
//
//  알림의 「완료」 버튼 처리. (BL-066 · BL-067)
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
