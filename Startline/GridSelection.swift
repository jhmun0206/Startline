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
        case event(String)
        case task(UUID)
    }

    private(set) var current: Item?

    /// 함께 선명해질 일정들.
    private(set) var highlightedEventIDs: Set<String> = []
    /// 함께 선명해질 할 일들.
    private(set) var highlightedTaskIDs: Set<UUID> = []

    var isEmpty: Bool { current == nil }

    // MARK: - 고르기

    /// 일정을 고른다. 그 일정에 딸린 할 일이 함께 선명해진다.
    func select(eventID: String, among tasks: [ResolvedTask]) {
        current = .event(eventID)
        highlightedEventIDs = [eventID]
        highlightedTaskIDs = Set(
            tasks.filter { $0.task.parentEventID == eventID }.map(\.id)
        )
    }

    /// 할 일을 고른다. 부모 일정과 **형제 할 일**이 함께 선명해진다.
    func select(task: ResolvedTask, among tasks: [ResolvedTask]) {
        current = .task(task.id)

        guard let parentID = task.task.parentEventID else {
            // 독립 할 일은 저 혼자다.
            highlightedEventIDs = []
            highlightedTaskIDs = [task.id]
            return
        }

        highlightedEventIDs = [parentID]
        highlightedTaskIDs = Set(
            tasks.filter { $0.task.parentEventID == parentID }.map(\.id)
        )
    }

    func clear() {
        current = nil
        highlightedEventIDs = []
        highlightedTaskIDs = []
    }

    // MARK: - 판정

    /// 중복 등록된 일정은 식별자가 여럿이므로 하나라도 걸리면 같은 일정으로 본다.
    func isHighlighted(anyOf eventIDs: [String]) -> Bool {
        eventIDs.contains { highlightedEventIDs.contains($0) }
    }

    func isSelected(anyOf eventIDs: [String]) -> Bool {
        guard case .event(let id) = current else { return false }
        return eventIDs.contains(id)
    }

    func isHighlighted(taskID: UUID) -> Bool {
        highlightedTaskIDs.contains(taskID)
    }

    func isSelected(taskID: UUID) -> Bool {
        current == .task(taskID)
    }
}
