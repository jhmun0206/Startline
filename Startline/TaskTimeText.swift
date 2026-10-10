//
//  TaskTimeText.swift
//  Startline
//
//  할 일 행 아래 회색 줄 — **마감과 알림 시각만** 말한다. 이 문구를 만드는 곳은 여기 하나다.
//  우측 패널 할 일 행과 그리드 미리보기가 같은 함수를 쓴다. 두 곳이 다르게 말하면 안 된다.
//

import Foundation

/// 할 일의 시각을 적는 규칙.
///
/// **상태어를 쓰지 않는다.** 「오늘 시작」·「늦음」은 오른쪽 배지가 말한다.
/// 예전에는 회색 줄이 「오늘 시작 · 24시간 걸림」, 배지가 「오늘 시작」이라 같은 말이 두 번 나왔다.
///
///     미완료      「마감 내일 저녁 7시 · 알림 오늘 저녁 7시」
///     알림 없음    「마감 내일 저녁 7시」
///     기한 지남    「10월 8일 (수) 저녁 7시까지였어요」   (배지 「늦음」과 다른 말로)
///
/// 소요시간(「N시간 걸림」)은 쓰지 않는다. 그 개념은 없어졌다. 예전 소요시간 데이터도
/// 알림 시각(마감 − 소요시간으로 해석한 값)으로 같은 형식에 들어간다.
///
/// 명세서 5.4 — 남은 시간·지난 시간을 숫자로 환산하지 않는다. 시각만 밝힌다.
nonisolated enum TaskTimeText {

    /// 「오늘 저녁 7시」 / 「내일 아침 9시」 / 「10월 11일 (토) 저녁 7시」
    static func moment(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = StartlineFormat.spokenTime(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return "오늘 \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "내일 \(time)"
        }
        return "\(StartlineFormat.spokenDay.string(from: date)) \(time)"
    }

    /// 「마감 …」
    static func due(_ date: Date, now: Date, calendar: Calendar) -> String {
        "마감 \(moment(date, now: now, calendar: calendar))"
    }

    /// 「알림 …」
    static func alarm(_ date: Date, now: Date, calendar: Calendar) -> String {
        "알림 \(moment(date, now: now, calendar: calendar))"
    }

    /// 할 일 행의 회색 줄 전체.
    ///
    /// - Parameters:
    ///   - effectiveDueAt: 마감. 사용자가 입력한 값(또는 부모 기준으로 계산한 값) 그대로.
    ///   - alarmAt: 알림 시각. `startDeadline` 이 이것이다. 「알림 없음」이면 `nil`.
    ///   - isMissed: 마감이 지났고 끝내지 않았는지. 그러면 알림은 말하지 않는다.
    static func detail(
        effectiveDueAt: Date?,
        alarmAt: Date?,
        isMissed: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard let effectiveDueAt else { return "마감 없음" }

        if isMissed {
            return "\(moment(effectiveDueAt, now: now, calendar: calendar))까지였어요"
        }

        var parts = [due(effectiveDueAt, now: now, calendar: calendar)]
        if let alarmAt {
            parts.append(alarm(alarmAt, now: now, calendar: calendar))
        }
        return parts.joined(separator: " · ")
    }
}
