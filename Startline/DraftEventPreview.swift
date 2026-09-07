//
//  DraftEventPreview.swift
//  Startline
//
//  아직 저장되지 않은 일정을 그리드에 미리 보여주기 위한 공유 상태.
//
//  시트에 "9월 15일 ~ 9월 17일"이라고 적혀 있어도 캘린더에서 그 범위를 눈으로
//  확인할 수 없으면 날짜를 제대로 골랐는지 알 수 없다.
//  드래그하는 동안에도, 시트가 떠 있는 동안에도 같은 막대가 같은 자리에 보여야 한다.
//

import Foundation
import Observation

@Observable
final class DraftEventPreview {

    /// 그리드에 그릴 임시 막대의 범위. 없으면 아무것도 그리지 않는다.
    private(set) var range: ClosedRange<Date>?

    /// 드래그 중인지. 시트가 떠 있을 때와 구분해 표현을 달리한다.
    private(set) var isDragging = false

    func set(start: Date, end: Date, isDragging: Bool = false) {
        let lower = min(start, end)
        let upper = max(start, end)
        range = lower...upper
        self.isDragging = isDragging
    }

    func clear() {
        range = nil
        isDragging = false
    }
}
