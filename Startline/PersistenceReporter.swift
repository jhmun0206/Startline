//
//  PersistenceReporter.swift
//  Startline
//
//  SwiftData 저장을 명시적으로 수행하고, 실패를 화면까지 끌어올린다.
//
//  SwiftData 는 기본이 지연 저장이다. 변경만 해두고 앱이 죽으면 그대로 사라진다.
//  할 일 추가·수정·삭제·완료처럼 사용자가 "했다"고 인식하는 동작 직후에는
//  반드시 디스크까지 내려가야 한다.
//

import Foundation
import Observation
import SwiftData

@Observable
final class PersistenceReporter {

    /// 마지막 저장 실패 메시지. 화면이 이 값을 보고 알린다.
    var lastErrorMessage: String?

    /// 변경을 즉시 디스크에 쓴다.
    ///
    /// 바뀐 게 없으면 아무 일도 하지 않는다.
    /// 실패하면 조용히 넘기지 않고 메시지를 남긴다.
    func commit(_ context: ModelContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            lastErrorMessage = "저장하지 못했어요. \(error.localizedDescription)"
        }
    }

    /// 값을 바꾸고 곧바로 저장한다.
    func perform(_ context: ModelContext, _ change: () -> Void) {
        change()
        commit(context)
    }

    func clearError() {
        lastErrorMessage = nil
    }
}
