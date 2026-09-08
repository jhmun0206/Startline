//
//  FeatureFlags.swift
//  Startline
//
//  실사용에서 필요한지 판단 중인 기능의 스위치.
//  지우지 않고 꺼 두었다가, 아쉬우면 다시 켠다.
//

import Foundation

enum FeatureFlags {

    /// 그리드 막대에 마우스를 올렸을 때 나오는 미리보기.
    ///
    /// 클릭을 가로채던 문제는 창 안 오버레이로 옮겨 해결했지만(BL-023),
    /// **미리보기 자체가 필요한지가 불확실해 당분간 꺼 둔다.**
    /// 끄고 지내면서 실제로 아쉬운지 확인한다. (BL-044)
    static let hoverPreview = false
}
