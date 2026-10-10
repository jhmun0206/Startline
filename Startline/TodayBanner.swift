//
//  TodayBanner.swift
//  Startline
//
//  우측 패널 맨 위 배너가 무엇을 말할지. 화면 없이 검증할 수 있게 뷰에서 뗐다.
//

import Foundation

// MARK: - 배너 상태

/// 「오늘 시작」 배너가 무엇을 말할지. **한 줄·개수만**이라는 형식은 그대로다.
///
/// 우선순위
///   ① 오늘 시작할 일이 남음        → 「오늘 시작할 일이 N개 남았어요」
///   ② ①이 0이고 기한 지난 미완료 있음 → 「기한 지난 할 일이 N개 있어요」
///   ③ 둘 다 0, 오늘 할 일이 있었음   → 「오늘 할 일을 다 마쳤어요. 수고했어요」
///   ④ 둘 다 0, 오늘 할 일이 없었음   → 「오늘 시작할 일이 0개예요」
///
/// ②가 생긴 이유 — 오늘 몫을 다 끝내면 「다 마쳤어요」가 떴는데, 바로 아래 「기한 지난 할 일」에
/// 미완료가 남아 있었다. 배너는 마감이 지난 일을 일부러 세지 않았고(그쪽은 섹션이 맡는다),
/// 섹션이 생긴 뒤로 「다 마쳤어요」가 틀린 말이 됐다.
nonisolated enum TodayBanner: Equatable {
    case remaining(Int)
    case missed(Int)
    case allDone
    case none

    static func state(tasks: [ResolvedTask], now: Date, calendar: Calendar) -> TodayBanner {
        let todays = tasks.filter { $0.isTodaysStart(now: now, calendar: calendar) }
        let remaining = todays.filter { !$0.task.isCompleted }.count
        if remaining > 0 { return .remaining(remaining) }

        let missed = tasks.filter { $0.isMissed(now: now) }.count
        if missed > 0 { return .missed(missed) }

        // 원래 있었는데 전부 체크한 경우에만 마쳤다고 말한다.
        return todays.isEmpty ? .none : .allDone
    }

    var message: String {
        switch self {
        case .remaining(let count): return "오늘 시작할 일이 \(count)개 남았어요"
        case .missed(let count): return "기한 지난 할 일이 \(count)개 있어요"
        case .allDone: return "오늘 할 일을 다 마쳤어요. 수고했어요"
        case .none: return "오늘 시작할 일이 0개예요"
        }
    }
}
