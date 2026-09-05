//
//  StartlineApp.swift
//  Startline
//
//  Created by 문정환 on 9/5/26.
//

import SwiftData
import SwiftUI

@main
struct StartlineApp: App {

    /// 명세서 8장 — 위젯이 같은 스토어를 읽어야 하므로 App Group 공유 컨테이너에 둔다.
    /// 나중에 옮기면 마이그레이션이 번거로우므로 처음부터 여기에 만든다.
    private static let appGroupID = "group.com.ericmun.startline"

    private let modelContainer: ModelContainer

    init() {
        modelContainer = Self.makeModelContainer()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }

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
        // 위젯과 공유되지 않으므로 Phase 2 진입 전에 원인을 확인해야 한다.
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("SwiftData 스토어를 열 수 없습니다: \(error)")
        }
    }
}
