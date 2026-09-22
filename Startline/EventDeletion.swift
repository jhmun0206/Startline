//
//  EventDeletion.swift
//  Startline
//
//  일정 삭제 확인 흐름. **일정 시트와 우측 패널이 같은 이것을 쓴다.** (명세서 8장)
//
//  예전에는 `EventEditorView` 안에만 있어서, 우측 패널에서 지우려면 시트를 열어야 했다.
//  꺼내서 공용으로 만들었다. 복사하지 않는다 — 되돌릴 수 없는 동작이 두 벌로 갈라지면
//  한쪽만 고쳐지는 날이 온다.
//

import EventKit
import SwiftUI

// MARK: - 문구

/// 삭제 확인 대화상자의 문구.
///
/// 순수 함수라 화면 없이 검증할 수 있다. 이 문구가 사용자가 무슨 일이 벌어질지
/// 아는 유일한 수단이라, 조용히 틀리면 안 된다.
nonisolated enum EventDeletionText {

    static func title(targetCount: Int) -> String {
        targetCount > 1 ? "\(targetCount)개를 함께 지울까요?" : "이 일정을 지울까요?"
    }

    /// 되돌릴 수 없고 다른 기기까지 번지는 일이라, 무슨 일이 벌어지는지 그대로 적는다.
    ///
    /// - Parameters:
    ///   - eventTitle: 대표 일정의 제목.
    ///   - calendarTitles: 지워질 일정들이 속한 캘린더 이름. 2개 이상이면 묶음이다.
    ///   - attachedTaskCount: 이 일정에 딸린 할 일 개수. 함께 지워지지 않는다.
    static func warning(
        eventTitle: String,
        calendarTitles: [String],
        attachedTaskCount: Int
    ) -> String {
        var lines = ["‘\(eventTitle)’를 지우면 되돌릴 수 없어요. 연결된 계정과 다른 기기에서도 사라져요."]

        // 한 줄로 보이지만 실제로는 여러 건인 경우. 몇 개가 어디서 사라지는지 밝힌다. (BL-048)
        if calendarTitles.count > 1 {
            lines.append(
                "이 줄에는 일정 \(calendarTitles.count)개가 묶여 있어요."
                + " \(calendarTitles.joined(separator: " · ")) 에서 모두 사라져요."
            )
        }

        if attachedTaskCount > 0 {
            lines.append("이 일정에 연결된 할 일 \(attachedTaskCount)개는 삭제되지 않고 남습니다.")
        }

        return lines.joined(separator: "\n\n")
    }
}

// MARK: - 요청

/// 「이것을 지울까요」 하고 물을 대상.
///
/// `nil` 이면 대화상자가 닫혀 있다.
struct EventDeletionRequest: Identifiable {
    /// 지울 일정들. 여러 캘린더에 중복 등록된 묶음이면 2건 이상이다. (BL-048)
    let events: [EKEvent]
    /// 이 일정에 딸린 할 일 개수. 문구에만 쓰고 함께 지우지는 않는다.
    let attachedTaskCount: Int

    var id: String {
        events.compactMap(\.eventIdentifier).joined(separator: "|")
    }

    var primary: EKEvent? { events.first }
    var isRecurring: Bool { primary?.hasRecurrenceRules == true }

    var alertTitle: String {
        EventDeletionText.title(targetCount: events.count)
    }

    var alertMessage: String {
        EventDeletionText.warning(
            eventTitle: primary?.title ?? "",
            calendarTitles: events.map { $0.calendar?.title ?? "(캘린더 없음)" },
            attachedTaskCount: attachedTaskCount
        )
    }
}

// MARK: - 대화상자

extension View {
    /// 일정 삭제 확인 대화상자를 붙인다.
    ///
    /// **할 일 삭제와 다르게 동작하는 것은 의도다.** 할 일은 우클릭 → 삭제로 바로 지워지지만
    /// 일정은 반드시 여기를 거친다. 「같은 패널인데 일관성이 없다」고 보고 이 확인을
    /// 걷어내지 말 것 —
    ///
    ///   할 일 삭제는 이 맥의 SwiftData 에서만 일어난다.
    ///   **일정 삭제는 되돌릴 수 없고 연결된 계정과 다른 기기에도 전파된다.**
    ///   (`CLAUDE.md`, 명세서 8장)
    ///
    /// 되돌리기가 생기면(BL-040) 그때 다시 판단한다.
    ///
    /// - Parameters:
    ///   - onDeleted: 지운 뒤 할 일. 시트는 자기를 닫고, 우측 패널은 아무것도 하지 않는다.
    ///   - onFailure: 실패 메시지를 받는다. **조용히 넘기면 화면에서 사라진 것이 실제로는 남는다.**
    func eventDeletionAlert(
        _ request: Binding<EventDeletionRequest?>,
        manager: CalendarManager,
        onDeleted: @escaping () -> Void = {},
        onFailure: @escaping (String) -> Void
    ) -> some View {
        modifier(
            EventDeletionAlert(
                request: request,
                manager: manager,
                onDeleted: onDeleted,
                onFailure: onFailure
            )
        )
    }
}

private struct EventDeletionAlert: ViewModifier {
    @Binding var request: EventDeletionRequest?
    let manager: CalendarManager
    let onDeleted: () -> Void
    let onFailure: (String) -> Void

    private var isPresented: Binding<Bool> {
        Binding(
            get: { request != nil },
            set: { if !$0 { request = nil } }
        )
    }

    func body(content: Content) -> some View {
        content.alert(
            request?.alertTitle ?? "",
            isPresented: isPresented,
            presenting: request
        ) { pending in
            // 반복 일정은 어디까지 지울지 묻는다. (BL-024)
            if pending.isRecurring {
                Button("이 일정만", role: .destructive) { delete(pending, span: .thisEvent) }
                Button("이후 모든 일정", role: .destructive) { delete(pending, span: .futureEvents) }
            } else {
                Button("지우기", role: .destructive) { delete(pending, span: .thisEvent) }
            }
            Button("그만두기", role: .cancel) {}
        } message: { pending in
            Text(pending.alertMessage)
        }
    }

    private func delete(_ pending: EventDeletionRequest, span: EKSpan) {
        // 묶음 전체를 지운다. 하나라도 실패하면 거기서 멈추고 알린다 —
        // 조용히 넘어가면 화면에서 사라진 것이 실제로는 남는다. (BL-048)
        do {
            for target in pending.events {
                try manager.deleteEvent(target, span: span)
            }
            request = nil
            onDeleted()
        } catch {
            request = nil
            onFailure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
