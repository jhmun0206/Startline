//
//  StartlineApp.swift
//  Startline
//
//  Created by 문정환 on 9/5/26.
//

import AppKit
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

    static let container: ModelContainer = makeModelContainer()

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([ManagedTask.self])

        if let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let storeURL = containerURL.appending(path: "Startline.store")
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            if let container = try? ModelContainer(for: schema, configurations: configuration) {
                return container
            }
        }

        // App Group 컨테이너를 못 얻은 경우의 폴백. 앱 기본 위치에 만든다.
        // 위젯과 공유되지 않으므로 Phase 2 진입 전에 원인을 확인해야 한다. (BL-013)
        do {
            return try ModelContainer(for: schema)
        } catch {
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
        case NotificationScheduler.startNowAction:
            await markStarted(identifier: identifier, content: content)

        case NotificationScheduler.snoozeAction:
            await Self.scheduler.snooze(
                identifier,
                title: content.title,
                body: content.body
            )

        default:
            break
        }
    }

    /// 「지금 시작」 — status = .inProgress, startedAt = now.
    /// 이 기록이 명세서 10장 캘리브레이션의 입력이 된다.
    @MainActor
    private func markStarted(identifier: String, content: UNNotificationContent) async {
        guard let parsed = PlannedNotification.parse(identifier: identifier) else { return }

        let context = StartlineStore.container.mainContext
        let targetID = parsed.taskID
        let descriptor = FetchDescriptor<ManagedTask>(
            predicate: #Predicate { $0.id == targetID }
        )

        guard let task = try? context.fetch(descriptor).first else { return }
        task.markStarted()

        do {
            try context.save()
            NSLog("[Startline] 알림에서 「지금 시작」 처리: \(task.title)")
        } catch {
            NSLog("[Startline] 「지금 시작」 저장 실패: \(error.localizedDescription)")
        }
    }
}
