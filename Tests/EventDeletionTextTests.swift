//
//  EventDeletionTextTests.swift
//  Startline — 일정 삭제 확인 문구 회귀 테스트
//
//  이 문구가 **사용자가 무슨 일이 벌어질지 아는 유일한 수단**이다.
//  일정 삭제는 되돌릴 수 없고 연결된 계정과 다른 기기에도 전파된다. (명세서 8장)
//  문구가 조용히 틀리면 사용자는 모르는 채로 지운다.
//
//  일정 시트와 우측 패널이 **같은 함수**를 쓴다. 두 벌로 갈라지면 한쪽만 고쳐진다.
//

import Foundation

func testEventDeletionText() {
    report.begin("일정 삭제 확인 문구")

    // ── 제목
    report.equal("단일 → 제목", EventDeletionText.title(targetCount: 1), "이 일정을 지울까요?")
    report.equal("묶음 2건 → 개수를 밝힌다", EventDeletionText.title(targetCount: 2), "2개를 함께 지울까요?")
    report.equal("묶음 3건", EventDeletionText.title(targetCount: 3), "3개를 함께 지울까요?")
    // 0 은 나오지 않지만, 나와도 단수 문구로 물러선다.
    report.equal("0 → 단수 문구로 물러섬", EventDeletionText.title(targetCount: 0), "이 일정을 지울까요?")

    // ── 단일 일정
    let single = EventDeletionText.warning(
        eventTitle: "[졸프] 전체 미팅",
        calendarTitles: ["개인"],
        attachedTaskCount: 0
    )
    report.check("단일 — 되돌릴 수 없다고 말한다", single.contains("되돌릴 수 없어요"))
    report.check("단일 — 다른 기기까지 번진다고 말한다", single.contains("다른 기기에서도 사라져요"))
    report.check("단일 — 제목이 들어간다", single.contains("[졸프] 전체 미팅"))
    report.check("단일 — 묶음 문구는 없다", !single.contains("묶여 있어요"))
    report.check("단일 — 할 일 문구는 없다", !single.contains("연결된 할 일"))
    report.equal("단일 — 한 단락", single.components(separatedBy: "\n\n").count, 1)

    // ── 묶음 (여러 캘린더에 중복 등록)
    let grouped = EventDeletionText.warning(
        eventTitle: "추석",
        calendarTitles: ["개인", "직장"],
        attachedTaskCount: 0
    )
    report.check("묶음 — 개수를 밝힌다", grouped.contains("일정 2개가 묶여 있어요"))
    report.check("묶음 — 캘린더명을 밝힌다", grouped.contains("개인 · 직장"))
    report.equal("묶음 — 두 단락", grouped.components(separatedBy: "\n\n").count, 2)

    // ── 딸린 할 일이 있을 때
    let withTasks = EventDeletionText.warning(
        eventTitle: "[졸프] 전체 미팅",
        calendarTitles: ["개인"],
        attachedTaskCount: 3
    )
    report.check("딸린 할 일 — 남는다고 말한다", withTasks.contains("할 일 3개는 삭제되지 않고 남습니다"))
    report.equal("딸린 할 일 — 두 단락", withTasks.components(separatedBy: "\n\n").count, 2)

    // ── 묶음 + 딸린 할 일
    let both = EventDeletionText.warning(
        eventTitle: "추석",
        calendarTitles: ["개인", "직장", "가족"],
        attachedTaskCount: 1
    )
    report.check("둘 다 — 묶음 문구", both.contains("일정 3개가 묶여 있어요"))
    report.check("둘 다 — 캘린더 셋", both.contains("개인 · 직장 · 가족"))
    report.check("둘 다 — 할 일 문구", both.contains("할 일 1개는 삭제되지 않고 남습니다"))
    report.equal("둘 다 — 세 단락", both.components(separatedBy: "\n\n").count, 3)

    // ── 원칙 4 — 내부 용어가 새어나오지 않는다
    let banned = ["착수", "리드타임", "실효마감", "마감시각", "메아리", "에코", "offset", "EKSpan"]
    for word in banned {
        report.check(
            "문구에 「\(word)」가 없다",
            !single.contains(word) && !grouped.contains(word) && !both.contains(word)
        )
    }

    // ── 캘린더 이름이 없는 경우에도 문구가 깨지지 않는다
    let noName = EventDeletionText.warning(
        eventTitle: "제목 없음",
        calendarTitles: ["(캘린더 없음)", "직장"],
        attachedTaskCount: 0
    )
    report.check("캘린더명이 비어도 문구가 만들어진다", noName.contains("(캘린더 없음) · 직장"))
}
