//
//  StartlineApp.swift
//  Startline
//
//  Created by 문정환 on 9/5/26.
//

import AppKit
import OSLog
import SwiftData
import SwiftUI
import UserNotifications

/// SwiftData 스토어를 앱과 알림 처리기가 함께 쓴다.
///
/// 알림 액션은 앱이 꺼져 있을 때도 들어온다. 그때 `App` 구조체의 인스턴스를
/// 거치지 않고 스토어에 닿아야 해서 한곳에 모아 둔다.
enum StartlineStore {

    /// 명세서 데이터 흐름 — 위젯이 같은 스토어를 읽어야 하므로 App Group 공유 컨테이너에 둔다.
    /// 나중에 옮기면 마이그레이션이 번거로우므로 처음부터 여기에 만든다.
    private static let appGroupID = "group.com.ericmun.startline"

    /// 스토어를 어디에 열었는지 남기는 기록.
    ///
    /// **이 로그는 임시 진단이 아니다. 걷어내지 말 것.** (BL-013)
    ///
    /// App Group 컨테이너를 못 열면 앱은 조용히 기본 위치로 물러선다. 그러면 화면에는
    /// 할 일이 **전부 사라진 것처럼** 보이는데, 데이터는 멀쩡히 원래 자리에 있다.
    /// 아무 흔적이 없으면 그 둘을 구분할 방법이 없다.
    static let log = Logger(subsystem: "com.ericmun.startline", category: "Store")

    static let container: ModelContainer = makeModelContainer()

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([ManagedTask.self])

        if let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let storeURL = containerURL.appending(path: "Startline.store")
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            do {
                let container = try ModelContainer(for: schema, configurations: configuration)
                // 「App Group 을 쓰기로 했다」가 아니라 **실제로 연 파일**을 남긴다.
                log.info("스토어 열림 — 공유 컨테이너 \(storeURL.path, privacy: .public)")
                return container
            } catch {
                // 실패 이유를 삼키지 않는다. 「폴백했다」만 알고 「왜」를 모르면 추적할 수 없다.
                log.error(
                    """
                    공유 컨테이너를 열지 못했다 — \(storeURL.path, privacy: .public) \
                    이유: \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        } else {
            log.error(
                "App Group 컨테이너 자체를 얻지 못했다 — \(appGroupID, privacy: .public)"
            )
        }

        // App Group 컨테이너를 못 얻은 경우의 폴백. 앱 기본 위치에 만든다.
        // 위젯과 공유되지 않으므로 Phase 2 진입 전에 원인을 확인해야 한다. (BL-013)
        //
        // **동작은 종전 그대로 둔다.** 이번에는 무슨 일이 일어났는지 보이게만 한다.
        do {
            let container = try ModelContainer(for: schema)
            let path = container.configurations.first?.url.path ?? "(경로 불명)"
            log.error("스토어 열림 — **폴백** 기본 위치 \(path, privacy: .public)")
            return container
        } catch {
            log.error("스토어를 열지 못했다 — \(error.localizedDescription, privacy: .public)")
            fatalError("SwiftData 스토어를 열 수 없습니다: \(error)")
        }
    }
}

@main
struct StartlineApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(StartlineStore.container)
    }
}

// MARK: - 알림 액션 처리

/// 알림의 「지금 시작」 / 「30분 미루기」를 받는다.
///
/// **앱이 실행 중이 아닐 때도 동작해야 한다.** 그래서 델리게이트를
/// `applicationWillFinishLaunching` 에서 붙인다. 이 시점보다 늦으면
/// 앱을 깨운 그 알림 응답을 놓친다.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// 화면 쪽에서도 같은 인스턴스를 쓴다.
    static let scheduler = NotificationScheduler()

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            Self.scheduler.registerCategories()
            await Self.scheduler.refreshAuthorization()
        }
    }

    /// 앱을 보고 있을 때도 배너를 띄운다. 안 그러면 앞에 두고 쓰는 동안 알림이 사라진다.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let content = response.notification.request.content

        switch response.actionIdentifier {
        case NotificationScheduler.completeAction:
            completeTask(identifier: identifier)

        case NotificationScheduler.snoozeAction:
            // 미룬 시각을 먼저 저장한다. 그래야 앱이 다시 예약해도 미룬 알림이 남는다. (BL-072)
            await MainActor.run {
                _ = NotificationSnooze.snooze(
                    identifier: identifier, in: StartlineStore.container.mainContext
                )
            }
            await Self.scheduler.snooze(
                identifier,
                title: content.title,
                body: content.body
            )

        default:
            break
        }
    }

    /// 알림의 「완료」. **앱이 꺼져 있다가 이 버튼으로 깨어나도 저장돼야 한다.**
    @MainActor
    private func completeTask(identifier: String) {
        let context = StartlineStore.container.mainContext
        switch NotificationCompletion.complete(identifier: identifier, in: context) {
        case .completed(let title):
            NSLog("[Startline] 알림에서 「완료」 처리: \(title)")
        case .notFound:
            NSLog("[Startline] 「완료」 — 할 일을 찾지 못했다: \(identifier)")
        case .saveFailed(let message):
            NSLog("[Startline] 「완료」 저장 실패: \(message)")
        }
    }

}
