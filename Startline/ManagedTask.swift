//
//  ManagedTask.swift
//  Startline
//
//  명세서 5장 — 착수일 역산 엔진.
//  5.1 데이터 모델 / 5.2 착수일 계산 / 5.4 남은 시간 표시 정책
//

import Foundation
import SwiftData

// MARK: - 열거형

enum TaskStatus: String, Codable, CaseIterable {
    case notStarted
    case inProgress
    case done
    case missed

    var label: String {
        switch self {
        case .notStarted: return "미시작"
        case .inProgress: return "진행 중"
        case .done: return "완료"
        case .missed: return "놓침"
        }
    }
}

/// 리드타임 방식. (명세서 5.1)
enum LeadTime: Equatable {
    /// 소요시간 역산.
    case durationBased
    /// N일 전.
    case fixed(days: Int)
    /// N시간 전.
    case fixedHours(Int)
    /// 리드타임 없음.
    case none
}

/// `LeadTime` 의 저장용 종류값.
///
/// 연관값을 가진 열거형을 SwiftData 속성으로 직접 두지 않고 종류 + 값으로 나눠 저장한다.
/// 쿼리와 마이그레이션이 예측 가능해지고, 연관값 열거형의 SwiftData 지원 편차를 피할 수 있다.
enum LeadTimeKind: String, Codable, CaseIterable {
    case durationBased
    case fixedDays
    case fixedHours
    case none

    var label: String {
        switch self {
        case .durationBased: return "소요시간 역산"
        case .fixedDays: return "N일 전"
        case .fixedHours: return "N시간 전"
        case .none: return "없음"
        }
    }
}

/// 착수 판정. 명세서 5.4에 따라 남은 시간을 숫자로 내보내지 않고 판정만 전달한다.
/// 화면에는 「여유 / 오늘 시작 / 늦음」으로 나간다. (원칙 4 — "착수"는 내부 용어)
enum StartJudgment {
    case relaxed
    case startToday
    case overdue

    var label: String {
        switch self {
        case .relaxed: return "여유"
        case .startToday: return "오늘 시작"
        case .overdue: return "늦음"
        }
    }
}

// MARK: - 모델

@Model
final class ManagedTask {

    var id: UUID = UUID()
    var title: String = ""

    // ─── 마감 (명세서 4.1) ───

    /// 절대 마감. 독립 할 일이 쓴다.
    ///
    /// 부모 일정이 붙은 할 일에서는 **마지막으로 계산된 실효마감의 사본**을 여기 보관한다.
    /// 부모 일정이 삭제됐을 때 이 값을 확정 마감으로 승격시켜 독립 할 일로 전환한다. (명세서 4.2)
    var dueAt: Date?

    /// 부모 일정. `EKEvent.eventIdentifier`.
    var parentEventID: String?

    /// 반복 일정의 회차 특정용. `EKEvent.eventIdentifier` 는 회차별로 같을 수 있다. (명세서 7.4)
    var parentOccurrenceDate: Date?

    /// 부모 일정 시작시각 기준 상대 마감. 음수가 "며칠 전".
    /// 절대 시각이 아니라 상대값으로 저장해야 부모가 옮겨질 때 함께 따라간다. (명세서 7.3)
    var offsetFromParent: TimeInterval?

    /// 사용자가 입력한 소요시간. **앱이 임의로 변형하지 않는다.** (명세서 원칙 1)
    /// 착수일 계산에는 항상 이 값만 쓴다.
    var estimatedDuration: TimeInterval?

    /// AI·과거기록에서 온 참고값. 화면에 나란히 보여주기 위한 값이며 계산에 쓰지 않는다.
    /// (명세서 5.1, 7.3 — Phase 2에서 채워진다)
    var referenceDuration: TimeInterval?

    /// `leadTime` 의 저장 표현.
    var leadTimeKind: LeadTimeKind = LeadTimeKind.durationBased
    var leadTimeValue: Int = 0

    var status: TaskStatus = TaskStatus.notStarted
    var startedAt: Date?
    var completedAt: Date?
    var createdAt: Date = Date()

    /// 독립 할 일.
    init(
        title: String,
        dueAt: Date?,
        estimatedDuration: TimeInterval? = nil,
        leadTime: LeadTime = .durationBased
    ) {
        self.id = UUID()
        self.title = title
        self.dueAt = dueAt
        self.estimatedDuration = estimatedDuration
        self.referenceDuration = nil
        self.leadTimeKind = .durationBased
        self.leadTimeValue = 0
        self.status = .notStarted
        self.createdAt = Date()
        self.leadTime = leadTime
    }

    /// 일정에 딸린 할 일. 마감을 부모 기준 상대값으로 저장한다. (명세서 7.2)
    init(
        title: String,
        parentEventID: String,
        parentOccurrenceDate: Date?,
        offsetFromParent: TimeInterval,
        lastKnownDueAt: Date?,
        estimatedDuration: TimeInterval? = nil,
        leadTime: LeadTime = .durationBased
    ) {
        self.id = UUID()
        self.title = title
        self.dueAt = lastKnownDueAt
        self.parentEventID = parentEventID
        self.parentOccurrenceDate = parentOccurrenceDate
        self.offsetFromParent = offsetFromParent
        self.estimatedDuration = estimatedDuration
        self.referenceDuration = nil
        self.leadTimeKind = .durationBased
        self.leadTimeValue = 0
        self.status = .notStarted
        self.createdAt = Date()
        self.leadTime = leadTime
    }

    /// 저장된 종류 + 값을 명세서 5.1의 `LeadTime` 으로 다시 조립한다.
    var leadTime: LeadTime {
        get {
            switch leadTimeKind {
            case .durationBased: return .durationBased
            case .fixedDays: return .fixed(days: leadTimeValue)
            case .fixedHours: return .fixedHours(leadTimeValue)
            case .none: return .none
            }
        }
        set {
            switch newValue {
            case .durationBased:
                leadTimeKind = .durationBased
                leadTimeValue = 0
            case .fixed(let days):
                leadTimeKind = .fixedDays
                leadTimeValue = days
            case .fixedHours(let hours):
                leadTimeKind = .fixedHours
                leadTimeValue = hours
            case .none:
                leadTimeKind = .none
                leadTimeValue = 0
            }
        }
    }
}

// MARK: - 마감 결정과 착수일 계산 (명세서 4.2, 4.3)

extension ManagedTask {

    /// 일정에 딸린 할 일인지.
    var isAttached: Bool { parentEventID != nil }

    /// 실효마감. (명세서 4.2)
    ///
    /// 부모 일정이 있으면 `부모 시작시각 + offsetFromParent`, 없으면 `dueAt`.
    /// 부모가 있으나 아직 찾지 못한 경우에는 마지막으로 확정된 `dueAt` 으로 물러선다.
    ///
    /// - Parameter parentStart: 부모 일정의 시작시각. 부모를 못 찾았으면 `nil`.
    func effectiveDueAt(parentStart: Date?) -> Date? {
        guard isAttached else { return dueAt }
        guard let parentStart, let offsetFromParent else { return dueAt }
        return parentStart.addingTimeInterval(offsetFromParent)
    }

    /// 착수마감 = 실효마감 − 리드타임. (명세서 4.3)
    ///
    /// **버퍼 배수를 곱하지 않는다.** (원칙 1)
    /// 사용자가 입력한 `estimatedDuration` 을 그대로 뺀다.
    func startDeadline(effectiveDueAt: Date?, calendar: Calendar = .current) -> Date? {
        guard let due = effectiveDueAt else { return nil }

        switch leadTime {
        case .durationBased:
            guard let estimatedDuration, estimatedDuration > 0 else { return nil }
            return due.addingTimeInterval(-estimatedDuration)

        case .fixed(let days):
            // 일 단위는 캘린더 연산으로 뺀다. 서머타임 등에서 하루가 24시간이 아닐 수 있다.
            return calendar.date(byAdding: .day, value: -days, to: due)

        case .fixedHours(let hours):
            return calendar.date(byAdding: .hour, value: -hours, to: due)

        case .none:
            return nil
        }
    }

    /// 저장된 `dueAt` 만으로 계산하는 편의 메서드.
    ///
    /// 독립 할 일에서는 정확하다. 부모가 붙은 할 일에서는 마지막으로 확정된 값을 쓰므로,
    /// 부모를 조회할 수 있는 자리에서는 `startDeadline(effectiveDueAt:calendar:)` 를 쓴다.
    func startDeadline(calendar: Calendar = .current) -> Date? {
        startDeadline(effectiveDueAt: dueAt, calendar: calendar)
    }

    /// 착수 판정. 숫자가 아니라 판정만 돌려준다. (명세서 5.4)
    ///
    /// 아직 시작하지 않은 항목에 대해서만 의미가 있다.
    /// 이미 시작했거나 완료한 항목, 리드타임이 없는 항목은 `nil`.
    func judgment(
        effectiveDueAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> StartJudgment? {
        guard status == .notStarted else { return nil }
        guard let deadline = startDeadline(effectiveDueAt: effectiveDueAt, calendar: calendar) else { return nil }

        // 착수마감이 지났으면 지연. (명세서 8.1 위험 단계)
        if now > deadline { return .overdue }
        // 오늘이 착수마감이면 오늘 착수. (명세서 8.1 착수 단계)
        if calendar.isDate(deadline, inSameDayAs: now) { return .startToday }
        return .relaxed
    }

    func judgment(now: Date = Date(), calendar: Calendar = .current) -> StartJudgment? {
        judgment(effectiveDueAt: dueAt, now: now, calendar: calendar)
    }

    // MARK: - 상태 전이

    /// "지금 시작" — 이 기록이 명세서 9장 캘리브레이션의 입력이 된다.
    func markStarted(at date: Date = Date()) {
        guard status == .notStarted || status == .missed else { return }
        status = .inProgress
        startedAt = date
    }

    func markDone(at date: Date = Date()) {
        status = .done
        completedAt = date
    }

    func markNotStarted() {
        status = .notStarted
        startedAt = nil
        completedAt = nil
    }

    // MARK: - 부모 연결 해제 (명세서 4.2)

    /// 부모 일정이 삭제됐을 때 독립 할 일로 전환한다.
    ///
    /// 할 일을 함께 지우지 않는다. 준비 작업 자체는 여전히 유효할 수 있다.
    /// 마지막으로 계산된 실효마감을 확정 마감으로 승격시킨다.
    func detachFromParent(lastKnownDueAt: Date?) {
        if let lastKnownDueAt { dueAt = lastKnownDueAt }
        parentEventID = nil
        parentOccurrenceDate = nil
        offsetFromParent = nil
    }
}

// MARK: - 소요시간 프리셋 (명세서 12장 「소요시간 입력 마찰」 대응)

/// 소요시간 입력 프리셋.
///
/// 라벨에 실제 값을 그대로 드러낸다. 「반나절 / 하루」는 달력 시간(12/24시간)과
/// 업무시간(4/8시간) 중 어느 쪽인지 사람마다 달리 읽어 착수마감이 크게 달라진다.
/// 업무시간 기준으로 갈지는 명세서 13장 #2 로 열려 있다. (BL-012)
struct DurationPreset: Identifiable {
    let label: String
    let duration: TimeInterval

    var id: String { label }

    static let all: [DurationPreset] = [
        DurationPreset(label: "30분", duration: 30 * 60),
        DurationPreset(label: "1시간", duration: 60 * 60),
        DurationPreset(label: "3시간", duration: 3 * 60 * 60),
        DurationPreset(label: "12시간", duration: 12 * 60 * 60),
        DurationPreset(label: "24시간", duration: 24 * 60 * 60),
    ]
}

// MARK: - 표시 형식

nonisolated enum StartlineFormat {

    /// "9월 23일 (수) 14:00"
    static let dayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .startlineDisplay
        formatter.dateFormat = "M월 d일 (E) HH:mm"
        return formatter
    }()

    /// "2026년 9월 23일 (수) 14:00"
    static let fullDayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .startlineDisplay
        formatter.dateFormat = "yyyy년 M월 d일 (E) HH:mm"
        return formatter
    }()

    /// "9월 27일 (일)"
    static let spokenDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .startlineDisplay
        formatter.dateFormat = "M월 d일 (E)"
        return formatter
    }()

    /// "9월 27일 (일) 저녁 8시 59분" — 사람이 말하는 방식으로 시각을 적는다.
    /// 명세서 5.4 — 남은 시간을 환산한 숫자는 넣지 않는다. 시점만 말한다.
    static func spokenDayTime(_ date: Date, calendar: Calendar = .current) -> String {
        let hour24 = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)

        let period: String
        switch hour24 {
        case 0..<6: period = "새벽"
        case 6..<12: period = "아침"
        case 12..<18: period = "오후"
        case 18..<21: period = "저녁"
        default: period = "밤"
        }

        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let time = minute == 0
            ? "\(period) \(hour12)시"
            : "\(period) \(hour12)시 \(minute)분"

        return "\(spokenDay.string(from: date)) \(time)"
    }

    /// 소요시간을 "1시간 30분" 형태로.
    static func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval.rounded()) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        switch (hours, minutes) {
        case (0, 0): return "-"
        case (0, _): return "\(minutes)분"
        case (_, 0): return "\(hours)시간"
        default: return "\(hours)시간 \(minutes)분"
        }
    }
}
