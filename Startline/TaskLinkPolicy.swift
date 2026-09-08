//
//  TaskLinkPolicy.swift
//  Startline
//
//  할 일과 부모 일정의 연결을 바꾸는 결정을 한곳에 모은 곳. (명세서 4.2, 7장)
//
//  이 파일이 따로 있는 이유가 있다.
//
//  `parentEventID` 가 조용히 `NULL` 로 지워져 되돌릴 수 없는 데이터 유실이 났다. (BL-045)
//  원인은 "부모를 못 찾았다"를 "부모가 삭제됐다"로 단정한 것이었고, 그 판단이 화면 코드
//  안에 흩어져 있어 아무도 검토하지 못했다.
//
//  그래서 판단을 **뷰에서 떼어내 순수 함수로** 옮겼다. 화면 없이 돌려볼 수 있으므로
//  `Tests/LinkIntegrityTests.swift` 가 매번 검증한다.
//

import Foundation
import OSLog

/// 연결을 바꾸는 판단.
///
/// 저장 시점에 "연결을 어떻게 할지"를 정하는 곳은 여기 하나뿐이다.
enum TaskLinkPolicy {

    /// 연결을 **끊는** 이유.
    ///
    /// 케이스가 하나뿐인 것은 실수가 아니라 의도다. 연결을 끊어도 되는 경우는
    /// **사용자가 직접 「특정 날짜」를 고른 것** 하나밖에 없다. 새 이유를 들이려면
    /// 여기에 케이스를 더해야 하고, 그 추가는 리뷰에서 눈에 띈다.
    ///
    /// 특히 「부모를 못 찾음」은 이유가 **아니다.** 조회 실패는 계정 동기화 중이거나
    /// 식별자가 바뀌는 동안에도 일어나며, 그때 연결을 지우면 어느 일정에 붙어 있었는지가
    /// 함께 사라져 복구할 수 없다.
    enum DetachReason: String {
        case userChoseFixedDate = "사용자가 「특정 날짜」를 골랐다"
    }

    /// 저장된 연결에 **손대지 않는** 이유.
    enum KeepReason: String {
        case parentUnresolved = "부모를 아직 찾지 못했다"
    }

    /// 저장 버튼을 눌렀을 때 연결에 할 일.
    enum Decision: Equatable {
        /// 연결을 끊고 독립 할 일로 만든다.
        case detach(DetachReason)
        /// 부모를 확정해 연결을 쓴다.
        case link(eventID: String, occurrenceDate: Date?, offset: TimeInterval, dueAt: Date?)
        /// 저장된 값을 그대로 둔다. **아무것도 지우지 않는다.**
        case keepStored(KeepReason)
    }

    /// 할 일 편집 화면에서 저장을 눌렀을 때의 판단.
    ///
    /// - Parameters:
    ///   - wantsAttachment: 사용자가 「일정에 맞춰」를 고른 상태인지. `false` 면 「특정 날짜」다.
    ///   - resolvedParentID: 화면이 실제로 집어낸 부모의 식별자. 못 찾았으면 `nil`.
    ///   - resolvedParentStart: 그 부모의 시작시각.
    ///   - offsetFromParent: 부모 시작시각 기준 상대 마감. 음수가 "며칠 전".
    ///   - fixedDueAt: 「특정 날짜」로 고른 절대 마감.
    ///   - effectiveDueAt: 부모 기준으로 계산된 실효마감. 사본으로 남길 값.
    static func decideOnSave(
        wantsAttachment: Bool,
        resolvedParentID: String?,
        resolvedParentStart: Date?,
        offsetFromParent: TimeInterval,
        fixedDueAt: Date?,
        effectiveDueAt: Date?
    ) -> Decision {
        // 사용자가 「특정 날짜」를 골랐다. 연결을 끊어도 되는 유일한 경우.
        guard wantsAttachment else { return .detach(.userChoseFixedDate) }

        // 「일정에 맞춰」인데 부모를 못 집었다.
        //
        // 예전에는 여기서 연결을 끊었다. 화면이 부모를 못 찾은 것뿐인데
        // 사용자는 저장만 눌렀다가 관계를 잃었다. 이제는 손대지 않는다. (BL-045)
        guard let resolvedParentID else { return .keepStored(.parentUnresolved) }

        return .link(
            eventID: resolvedParentID,
            occurrenceDate: resolvedParentStart,
            offset: offsetFromParent,
            dueAt: effectiveDueAt
        )
    }

    /// 연결이 끊길 때 남기는 기록.
    ///
    /// 이번 유실은 **아무 흔적도 남지 않아** 원인을 찾는 데 시간이 걸렸다.
    /// 앞으로는 언제·무엇이·왜 끊겼는지가 콘솔에 남는다.
    static let log = Logger(subsystem: "com.ericmun.startline", category: "TaskLink")
}
