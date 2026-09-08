//
//  GridSelection.swift
//  Startline
//
//  그리드와 우측 패널이 함께 보는 선택 상태.
//
//  한 번 클릭은 고르기, 두 번 클릭은 고치기다.
//  고르면 **연결된 것들이 함께 선명해진다** — 일정과 그 일정에 딸린 할 일들.
//  부모-자식 관계는 목록만 봐서는 잘 드러나지 않는데, 고를 때 같이 밝아지면 한눈에 보인다.
//

import Foundation
import Observation

@Observable
final class GridSelection {

    enum Item: Equatable {
        /// 일정 **회차** 키. 반복 일정은 회차마다 다르다.
        case event(String)
        case task(UUID)
    }

    private(set) var current: Item?

    /// 함께 선명해질 일정 **회차**들.
    private(set) var highlightedEventKeys: Set<String> = []
    /// 함께 선명해질 할 일들.
    private(set) var highlightedTaskIDs: Set<UUID> = []

    var isEmpty: Bool { current == nil }

    // MARK: - 고르기

    /// 일정 **회차**를 고른다. 그 회차에 딸린 할 일이 함께 선명해진다.
    ///
    /// 반복 일정의 다른 회차는 관계가 아니므로 함께 밝히지 않는다.
    func select(occurrenceKeys keys: [String], among tasks: [ResolvedTask]) {
        guard let first = keys.first else { return }
        current = .event(first)
        highlightedEventKeys = Set(keys)
        highlightedTaskIDs = Set(
            tasks.filter { resolved in
                guard let key = resolved.parentOccurrenceKey else { return false }
                return keys.contains(key)
            }.map(\.id)
        )
    }

    /// 할 일을 고른다. **그 회차의** 부모 일정과 형제 할 일이 함께 선명해진다.
    func select(task: ResolvedTask, among tasks: [ResolvedTask]) {
        current = .task(task.id)

        guard let key = task.parentOccurrenceKey else {
            // 독립 할 일이거나 부모를 아직 못 찾았으면 저 혼자다.
            highlightedEventKeys = []
            highlightedTaskIDs = [task.id]
            return
        }

        highlightedEventKeys = [key]
        highlightedTaskIDs = Set(
            tasks.filter { $0.parentOccurrenceKey == key }.map(\.id)
        )
    }

    func clear() {
        current = nil
        highlightedEventKeys = []
        highlightedTaskIDs = []
    }

    // MARK: - 판정

    /// 중복 등록된 일정은 회차 키가 여럿이므로 하나라도 걸리면 같은 것으로 본다.
    func isHighlighted(anyOf occurrenceKeys: [String]) -> Bool {
        occurrenceKeys.contains { highlightedEventKeys.contains($0) }
    }

    func isSelected(anyOf occurrenceKeys: [String]) -> Bool {
        guard case .event(let key) = current else { return false }
        return occurrenceKeys.contains(key)
    }

    func isHighlighted(taskID: UUID) -> Bool {
        highlightedTaskIDs.contains(taskID)
    }

    func isSelected(taskID: UUID) -> Bool {
        current == .task(taskID)
    }
}
