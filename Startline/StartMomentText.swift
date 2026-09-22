//
//  StartMomentText.swift
//  Startline
//
//  「언제 시작해야 하는지」를 사람 말로 적는 곳. **여기 하나뿐이다.** (명세서 5.4)
//
//  예전에는 네 군데가 각자 문구를 만들었다 — 우측 패널 행, 할 일 시트 안내,
//  호버 미리보기, 알림. 한 곳만 고치면 나머지가 옛 형태로 남는다.
//  이 프로젝트에서 실제로 그런 일이 났다.
//

import Foundation

/// 착수 시점을 적는 규칙.
///
/// **마감과 다른 날에 시작해야 하는 일은 날짜까지만 말한다.**
///
/// `착수일 = 마감시각 − 소요시간` 을 달력 시간으로 그대로 빼면 사람이 자는 시간이 나온다.
/// 12시간짜리 작업의 마감이 내일 16시면 착수는 오늘 04시다. 그 시각에 시작하는 사람은 없다.
///
/// **12시간짜리 작업의 시작 시각을 분 단위로 말하는 것 자체가 거짓 정밀도다.**
/// 사람은 12시간을 연속으로 하지 않는다. 앱이 실제로 아는 것은 「오늘 시작해야 한다」까지고,
/// 그 이상은 지어내는 것이다. 명세서 5.4 가 「4시간 30분 남았습니다」를 금지한 것과 같은 판단이다.
///
/// | 착수 시점 | 표시 |
/// |---|---|
/// | 마감과 **같은 날** | 시각까지 — 「9월 27일 (일) 저녁 8시 59분」 |
/// | 마감과 **다른 날** | 날짜만 — 「오늘」 / 「내일」 / 「9월 7일 (월)」 |
///
/// **계산식은 건드리지 않는다.** `startDeadline` 은 그대로 계산되고 그대로 저장된다.
/// 바뀌는 것은 화면에 적는 방식뿐이다.
///
/// 마감 시각은 **사용자가 입력한 값**이라 이 규칙을 적용하지 않는다. (원칙 1)
nonisolated enum StartMomentText {

    /// 날짜 부분과, 뒤에 「에」를 붙여야 하는지.
    ///
    /// 「오늘」·「내일」에는 「에」가 붙지 않는다 — 「오늘에 시작」은 한국어가 아니다.
    private static func day(
        startDeadline: Date,
        effectiveDueAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> (text: String, needsParticle: Bool) {
        // 마감과 같은 날이면 시각까지 말한다. 그날 안에서 언제인지가 실제로 뜻이 있다.
        if let effectiveDueAt,
           calendar.isDate(startDeadline, inSameDayAs: effectiveDueAt) {
            return (StartlineFormat.spokenDayTime(startDeadline, calendar: calendar), true)
        }

        if calendar.isDate(startDeadline, inSameDayAs: now) { return ("오늘", false) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(startDeadline, inSameDayAs: tomorrow) {
            return ("내일", false)
        }
        return (StartlineFormat.spokenDay.string(from: startDeadline), true)
    }

    /// 목록·미리보기용 짧은 꼬리. 「9월 27일 (일) 저녁 8시 59분에 시작」 / 「오늘 시작」
    static func short(
        startDeadline: Date,
        effectiveDueAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let d = day(startDeadline: startDeadline, effectiveDueAt: effectiveDueAt, now: now, calendar: calendar)
        return d.needsParticle ? "\(d.text)에 시작" : "\(d.text) 시작"
    }

    /// 시트 안내·알림용 한 문장. 「…에 시작해야 해요」 / 「오늘 시작해야 해요」
    static func sentence(
        startDeadline: Date,
        effectiveDueAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let d = day(startDeadline: startDeadline, effectiveDueAt: effectiveDueAt, now: now, calendar: calendar)
        return d.needsParticle ? "\(d.text)에 시작해야 해요" : "\(d.text) 시작해야 해요"
    }
}
