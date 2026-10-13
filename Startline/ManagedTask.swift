//
//  ManagedTask.swift
//  Startline
//
//  명세서 5장 — 착수일 역산 엔진.
//  5.1 데이터 모델 / 5.2 착수일 계산 / 5.4 남은 시간 표시 정책
//

import Foundation
import OSLog
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
    /// 알림 「30분 미루기」로 다시 울릴 시각. 미루지 않았으면 `nil`.
    ///
    /// 예전에는 미룬 사실을 저장하지 않아, 앱에서 무엇이든 저장해 알림을 다시 예약하면
    /// **미룬 알림이 지워졌다.** (BL-072) 이 값이 미래면 스케줄러가 원래 알림 시각 대신 이 시각에 예약한다.
    /// 미룬 **횟수**는 저장하지 않는다 (BL-032 폐기).
    ///
    /// 선택형 필드라 SwiftData 가 가벼운 이전으로 붙인다. 기존 행은 `nil` 로 읽힌다.
    var snoozedUntil: Date?
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

    /// 끝냈는지. **할 일의 상태를 묻는 곳은 전부 이것 하나만 본다.** (BL-066)
    ///
    /// 할 일은 완료 / 미완료 둘뿐이다. 저장값 `status` 에는 예전의 `inProgress`·`missed` 가
    /// 남아 있을 수 있는데, 완료가 아니면 모두 미완료로 읽는다.
    ///
    /// 예전에는 판정마다 `== .notStarted` 를 따로 봐서, **진행 중으로 바꾼 할 일은 배지도
    /// 알림도 사라졌다.** 손만 대 놓고 끝내지 못한 일이 조용해지는 버그였다.
    ///
    /// **`TaskStatus` 의 케이스를 지우지 말 것.** SwiftData 가 원시 문자열로 저장하고 있어
    /// 케이스를 지우면 그 값으로 저장된 행을 읽지 못한다.
    var isCompleted: Bool { status == .done }

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
            // 「N일 전」 = 정확히 N×24시간. 부모 기준 상대 마감(`offsetFromParent`)과 같은 기준이다.
            // (BL-022, DESIGN_direction 5장 ③) 서머타임이 없는 한국 시간대에서는 예전 캘린더 연산과 결과가 같다.
            return due.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)

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
        guard !isCompleted else { return nil }

        // 「늦음」은 **마감이 지난 뒤에만** 붙는다. 「기한 지난 할 일」(isMissed)과 같은 규칙이다.
        // 예전에는 시작 시점이 지나면 붙어서, 「1일 전」 알림이 울린 뒤 마감 전인데도 「늦음」이었다.
        // 알림이 없는 할 일도 마감이 지나면 늦은 것이다. 그래서 알림 시점보다 먼저 본다.
        if let effectiveDueAt, effectiveDueAt < now { return .overdue }

        guard let alarm = startDeadline(effectiveDueAt: effectiveDueAt, calendar: calendar) else { return nil }

        // 알림이 오늘이거나 이미 울렸으면 「오늘 시작」. 배너가 「오늘 몫」으로 세는 것과 같다.
        if alarm <= now || calendar.isDate(alarm, inSameDayAs: now) { return .startToday }
        return .relaxed
    }

    func judgment(now: Date = Date(), calendar: Calendar = .current) -> StartJudgment? {
        judgment(effectiveDueAt: dueAt, now: now, calendar: calendar)
    }

    // MARK: - 상태 전이

    /// "지금 시작" — 이 기록이 명세서 9장 캘리브레이션의 입력이 된다.

    func markDone(at date: Date = Date()) {
        status = .done
        completedAt = date
        // 끝낸 일을 다시 알릴 이유가 없다.
        snoozedUntil = nil
    }

    /// 알림 시각을 정하는 입력들. 사용자가 이것을 바꿨는지 가르는 데 쓴다.
    ///
    /// 딸린 할 일은 부모 기준 상대값(`offsetFromParent`)이 입력이고 `dueAt` 은 계산된 사본이라 보지 않는다.
    /// 사본은 부모가 옮겨질 때도 바뀌므로, 그것까지 보면 사용자가 손대지 않았는데 미룸이 지워진다.
    nonisolated struct AlarmInputs: Equatable {
        let due: Date?
        let parentEventID: String?
        let parentOccurrenceDate: Date?
        let offsetFromParent: TimeInterval?
        let leadTimeKind: LeadTimeKind
        let leadTimeValue: Int
        let estimatedDuration: TimeInterval?
    }

    var alarmInputs: AlarmInputs {
        AlarmInputs(
            due: isAttached ? nil : dueAt,
            parentEventID: parentEventID,
            parentOccurrenceDate: parentOccurrenceDate,
            offsetFromParent: offsetFromParent,
            leadTimeKind: leadTimeKind,
            leadTimeValue: leadTimeValue,
            estimatedDuration: estimatedDuration
        )
    }

    /// 사용자가 마감이나 알림을 바꿨으면 미룸을 지운다. 바뀐 알림 시각에 맞춰 새로 울린다. (BL-072)
    func clearSnoozeIfAlarmChanged(from before: AlarmInputs) {
        if alarmInputs != before { snoozedUntil = nil }
    }

    /// 미완료로 되돌린다.
    ///
    /// `startedAt` 은 건드리지 않는다. 예전 「지금 시작」이 남긴 기록이라 보존한다. (BL-066)
    func markNotStarted() {
        status = .notStarted
        completedAt = nil
    }

    // MARK: - 부모 연결 해제 (명세서 4.2)

    /// 부모 연결을 끊고 독립 할 일로 전환한다.
    ///
    /// 할 일을 함께 지우지 않는다. 준비 작업 자체는 여전히 유효할 수 있다.
    /// 마지막으로 계산된 실효마감을 확정 마감으로 승격시킨다.
    ///
    /// **`parentEventID` 를 `nil` 로 만드는 곳은 앱 전체에서 여기 하나뿐이다.**
    /// 한 번 끊으면 어느 일정에 붙어 있었는지가 함께 사라져 **되돌릴 수 없다.**
    /// 실제로 이 경로가 멀쩡한 연결을 지운 적이 있다. (BL-045)
    ///
    /// 그래서 이유를 인자로 **강제한다.** 「부모를 못 찾음」은 이유가 될 수 없고,
    /// 새 이유를 들이려면 `TaskLinkPolicy.DetachReason` 에 케이스를 더해야 한다.
    /// 끊긴 사실은 콘솔에 남아 나중에 추적할 수 있다.
    func detachFromParent(lastKnownDueAt: Date?, reason: TaskLinkPolicy.DetachReason) {
        if let parentEventID {
            TaskLinkPolicy.log.notice(
                """
                연결 해제 — 할 일 「\(self.title, privacy: .public)」 \
                부모 \(parentEventID, privacy: .public) \
                회차 \(self.parentOccurrenceDate?.description ?? "없음", privacy: .public) \
                이유 \(reason.rawValue, privacy: .public)
                """
            )
        }

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

    /// "9월 27일 (일) 오후 8:59" / "9월 27일 (일) 20:59"
    /// 명세서 5.4 — 남은 시간을 환산한 숫자는 넣지 않는다. 시점만 말한다.
    static func spokenDayTime(_ date: Date, calendar: Calendar = .current) -> String {
        "\(spokenDay.string(from: date)) \(spokenTime(date, calendar: calendar))"
    }

    /// 날짜 없이 시각만. **앱의 모든 시각은 이 함수를 거친다.** (DESIGN_direction 6장 ⑪)
    ///
    /// macOS 시스템 설정의 12/24시간을 따르는 짧은 형식이다.
    /// 12시간이면 "오후 8:59", 24시간이면 "20:59".
    ///
    /// 예전에는 "저녁 8시 59분"처럼 말하는 투로 적었고, 일정 카드는 "20:59" 로 따로 적어
    /// 같은 패널 안에서 형식이 섞였다. 형식을 하드코딩하지 않고 템플릿으로 만든다.
    static func spokenTime(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = .startlineDisplay
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(uses24HourClock ? "Hmm" : "hmma")
        return formatter.string(from: date)
    }

    /// 검증에서 12/24시간을 고정할 때만 쓴다. 앱에서는 늘 `nil` 이다.
    nonisolated(unsafe) static var hourCycleOverride: Bool?

    /// 시스템이 24시간 표기인지.
    ///
    /// 앱은 화면 언어를 ko_KR 로 고정하지만, 12/24시간은 사용자의 시스템 설정을 따른다.
    /// 그래서 고정 로케일이 아니라 현재 로케일의 시 표기(`j`)를 본다.
    static var uses24HourClock: Bool {
        if let hourCycleOverride { return hourCycleOverride }
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .autoupdatingCurrent) ?? ""
        return pattern.contains("H") || pattern.contains("k")
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
