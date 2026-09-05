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
enum StartJudgment {
    case relaxed
    case startToday
    case overdue

    var label: String {
        switch self {
        case .relaxed: return "여유"
        case .startToday: return "오늘 착수"
        case .overdue: return "지연"
        }
    }
}

// MARK: - 모델

@Model
final class ManagedTask {

    var id: UUID = UUID()
    var title: String = ""
    var dueAt: Date = Date()

    /// 사용자가 입력한 소요시간. **앱이 임의로 변형하지 않는다.** (명세서 원칙 1)
    /// 착수일 계산에는 항상 이 값만 쓴다.
    var estimatedDuration: TimeInterval?

    /// AI·과거기록에서 온 참고값. 화면에 나란히 보여주기 위한 값이며 계산에 쓰지 않는다.
    /// (명세서 5.1, 7.3 — Phase 2에서 채워진다)
    var referenceDuration: TimeInterval?

    /// `leadTime` 의 저장 표현.
    var leadTimeKind: LeadTimeKind = LeadTimeKind.durationBased
    var leadTimeValue: Int = 0

    var linkedEventID: String?
    var status: TaskStatus = TaskStatus.notStarted
    var startedAt: Date?
    var completedAt: Date?
    var createdAt: Date = Date()

    init(
        title: String,
        dueAt: Date,
        estimatedDuration: TimeInterval? = nil,
        leadTime: LeadTime = .durationBased,
        linkedEventID: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.dueAt = dueAt
        self.estimatedDuration = estimatedDuration
        self.referenceDuration = nil
        self.leadTimeKind = .durationBased
        self.leadTimeValue = 0
        self.linkedEventID = linkedEventID
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

// MARK: - 착수일 계산 (명세서 5.2)

extension ManagedTask {

    /// 착수마감 = 마감시각 − 리드타임.
    ///
    /// **버퍼 배수를 곱하지 않는다.** (명세서 원칙 1, 5.2)
    /// 사용자가 입력한 `estimatedDuration` 을 그대로 뺀다.
    ///
    /// - Returns: 리드타임이 없거나 소요시간 역산인데 소요시간이 비어 있으면 `nil`.
    func startDeadline(calendar: Calendar = .current) -> Date? {
        switch leadTime {
        case .durationBased:
            guard let estimatedDuration, estimatedDuration > 0 else { return nil }
            return dueAt.addingTimeInterval(-estimatedDuration)

        case .fixed(let days):
            // 일 단위는 캘린더 연산으로 뺀다. 서머타임 등에서 하루가 24시간이 아닐 수 있다.
            return calendar.date(byAdding: .day, value: -days, to: dueAt)

        case .fixedHours(let hours):
            return calendar.date(byAdding: .hour, value: -hours, to: dueAt)

        case .none:
            return nil
        }
    }

    /// 착수 판정. 숫자가 아니라 판정만 돌려준다. (명세서 5.4)
    ///
    /// 아직 시작하지 않은 항목에 대해서만 의미가 있다.
    /// 이미 시작했거나 완료한 항목, 리드타임이 없는 항목은 `nil`.
    func judgment(now: Date = Date(), calendar: Calendar = .current) -> StartJudgment? {
        guard status == .notStarted else { return nil }
        guard let deadline = startDeadline(calendar: calendar) else { return nil }

        // 착수마감이 지났으면 지연. (명세서 5.3 위험 단계)
        if now > deadline { return .overdue }
        // 오늘이 착수마감이면 오늘 착수. (명세서 5.3 착수 단계)
        if calendar.isDate(deadline, inSameDayAs: now) { return .startToday }
        return .relaxed
    }

    /// 명세서 4.1 「오늘 착수」 영역에 들어갈 항목인지.
    /// 오늘이 착수마감인 것, 그리고 착수마감이 지났는데 아직 시작하지 않은 것.
    func needsStartAttention(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch judgment(now: now, calendar: calendar) {
        case .startToday, .overdue: return true
        case .relaxed, nil: return false
        }
    }

    // MARK: - 상태 전이

    /// "지금 시작" — 이 기록이 명세서 6장 캘리브레이션의 입력이 된다.
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
}

// MARK: - 소요시간 프리셋 (명세서 12장 「소요시간 입력 마찰」 대응)

/// 소요시간 입력 프리셋. 명세서 13장 #2 는 값이 미정이므로 아래는 잠정값이다.
/// 「반나절 = 12시간 / 하루 = 24시간」— 착수일 = 마감시각 − 소요시간 공식을
/// 달력 시간 그대로 해석한 것이다. (업무시간 기준 4/8시간이 아님)
struct DurationPreset: Identifiable {
    let label: String
    let duration: TimeInterval

    var id: String { label }

    static let all: [DurationPreset] = [
        DurationPreset(label: "30분", duration: 30 * 60),
        DurationPreset(label: "1시간", duration: 60 * 60),
        DurationPreset(label: "3시간", duration: 3 * 60 * 60),
        DurationPreset(label: "반나절", duration: 12 * 60 * 60),
        DurationPreset(label: "하루", duration: 24 * 60 * 60),
    ]
}

// MARK: - 표시 형식

enum StartlineFormat {

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
