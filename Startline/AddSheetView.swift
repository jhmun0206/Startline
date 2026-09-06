//
//  AddSheetView.swift
//  Startline
//
//  추가 시트. 「일정 추가」와 「할 일 추가」를 한 시트에서 오간다.
//
//  일정을 만든 직후 그 일정에 딸린 할 일로 바로 이어질 수 있어야
//  "미팅을 잡으면서 준비할 일도 같이 만든다"는 흐름이 성립한다.
//

import SwiftUI

struct AddSheetView: View {

    enum Tab: Hashable {
        case event
        case task
    }

    let manager: CalendarManager
    let defaultDate: Date
    /// 드래그로 고른 기간의 마지막 날.
    var defaultEndDate: Date?
    var initialTab: Tab = .event

    @State private var tab: Tab = .event

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("일정 추가").tag(Tab.event)
                Text("할 일 추가").tag(Tab.task)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Divider().padding(.top, 12)

            switch tab {
            case .event:
                // 준비 할 일은 이 폼 안에서 여러 개를 한 번에 적는다.
                EventEditorView(
                    manager: manager,
                    event: nil,
                    defaultDate: defaultDate,
                    defaultEndDate: defaultEndDate
                )
            case .task:
                TaskEditorView(
                    task: nil,
                    defaultDueDate: defaultDate,
                    manager: manager
                )
            }
        }
        .frame(width: 440)
        .onAppear { tab = initialTab }
    }
}
