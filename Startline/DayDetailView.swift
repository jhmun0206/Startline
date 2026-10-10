//
//  DayDetailView.swift
//  Startline
//
//  명세서 5.2 우측 3계층 — 「오늘 시작」 + 「일정」 + 「할 일」.
//

import Combine
import EventKit
import SwiftData
import SwiftUI

struct DayDetailView: View {
    let manager: CalendarManager
    /// 그리드에서 클릭한 일정. 값이 들어오면 편집 시트를 연다.
    @Binding var eventToOpen: DayEvent?
    /// 그리드에서 더블클릭한 날짜.
    @Binding var addOnDate: Date?
    /// 그리드에서 드래그로 고른 기간.
    @Binding var addRange: ClosedRange<Date>?
    /// 그리드에서 클릭한 할 일.
    @Binding var taskToOpen: ManagedTask?

    @Environment(\.modelContext) private var modelContext
    @Environment(PersistenceReporter.self) private var saver
    @Environment(GridSelection.self) private var selection

    // Phase 1 의 항목 수는 적어서 전체를 읽고 메모리에서 거른다. (BL-017)
    @Query(sort: \ManagedTask.createdAt) private var allTasks: [ManagedTask]

    /// 착수 판정이 시간에 따라 바뀌므로 주기적으로 갱신한다.
    @State private var now = Date()

    /// 순서를 정할 때 쓰는 완료 여부 — 화면에 **지금 보이는 자리**의 기준.
    ///
    /// 체크하자마자 아래로 날아가면, 잘못 눌렀을 때 그 행을 찾아 되돌리기 어렵다.
    /// 그래서 순서는 실제 값이 아니라 이 값으로 정하고, 바뀐 뒤 **1초 기다렸다가** 따라잡는다.
    /// 미완료로 되돌릴 때도 같다.
    ///
    /// 체크한 **뒤에** 붙잡는 방식이면 첫 화면이 이미 새 순서로 그려져 한 번 튀었다가 돌아온다.
    /// 이 값은 체크해도 곧바로 바뀌지 않으므로 그 순간에도 제자리다.
    @State private var orderedCompletion: [UUID: Bool] = [:]
    /// 따라잡기 예약 표식. 1초 안에 다시 누르면 먼저 건 것은 무효가 된다.
    @State private var reorderTokens: [UUID: UUID] = [:]

    /// 체크한 뒤 자리를 옮기기까지 기다리는 시간.
    private static let reorderDelay: Duration = .seconds(1)

    private func orderingCompletion(_ resolved: ResolvedTask) -> Bool {
        orderedCompletion[resolved.id] ?? resolved.task.isCompleted
    }

    private var completionSignature: [UUID: Bool] {
        Dictionary(resolvedTasks.map { ($0.id, $0.task.isCompleted) }, uniquingKeysWith: { a, _ in a })
    }

    /// 실제 완료 여부가 바뀌면 1초 뒤에 화면 순서를 따라잡는다.
    private func followCompletion(_ current: [UUID: Bool]) {
        // 사라진 할 일은 잊고, 처음 보는 할 일은 곧바로 맞춘다 (옮길 자리가 없다).
        orderedCompletion = orderedCompletion.filter { current[$0.key] != nil }
        for (id, value) in current where orderedCompletion[id] == nil {
            orderedCompletion[id] = value
        }

        for (id, value) in current where orderedCompletion[id] != value {
            let token = UUID()
            reorderTokens[id] = token
            Task { @MainActor in
                try? await Task.sleep(for: Self.reorderDelay)
                guard reorderTokens[id] == token else { return }
                reorderTokens[id] = nil
                // 그 사이 되돌렸으면 값이 같아져 움직이지 않는다.
                let latest = completionSignature[id]
                withAnimation(.easeInOut(duration: 0.3)) { orderedCompletion[id] = latest }
            }
        }
    }
    @State private var editingTask: ManagedTask?
    @State private var isAddingItem = false
    /// 「일정 추가」에서 만든 일정을 부모로 이어받은 할 일 입력.
    @State private var taskParentPreset: EKEvent?
    /// 부모 일정이 사라져 독립 할 일로 전환된 항목들. (명세서 4.2)
    @State private var detachedNotices: [DetachedTaskNotice] = []
    @State private var deletionRequest: EventDeletionRequest?
    /// 일정 삭제가 실패했을 때의 메시지. 조용히 넘기면 사라진 줄 알았던 것이 남는다.
    @State private var eventErrorMessage: String?

    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var resolver: TaskResolver {
        TaskResolver(manager: manager, now: now)
    }

    private var events: [DayEvent] {
        manager.events(on: manager.selectedDate)
    }

    private var resolvedTasks: [ResolvedTask] {
        resolver.resolve(allTasks)
    }

    /// 3계층 — 이 날 챙겨야 할 할 일.
    ///
    /// **착수일이 이 날인 것을 반드시 포함한다.** 이 앱은 착수일 관리가 존재 이유인데,
    /// 딸린 할 일을 부모 일정 카드 아래에만 두면 착수일 화면에서 그 할 일이 보이지 않는다.
    /// 부모 일정이 있는 날에 가야만 보이는 것은 정면으로 어긋난다.
    ///
    /// 포함 대상:
    /// - 이 날이 착수일인 할 일 (부모가 있든 없든)
    /// - 이 날이 마감일인 할 일
    /// - 착수일이 지났는데 아직 시작하지 않은 할 일 (오늘을 보고 있을 때)
    ///
    /// 부모 일정 카드 아래에도 나오는 것은 의도된 동작이다 — 일정 관점과 할 일 관점 둘 다 필요하다.
    /// 다만 같은 날 화면에 두 번 나오지는 않게 한다.
    /// 부모 일정 카드 안에 들어가는 할 일.
    ///
    /// 부모가 이 날에 있으면 그 카드 안에만 놓는다. 「할 일」 섹션에는 겹쳐 넣지 않는다.
    private var nestedTasks: [ResolvedTask] {
        var seen = Set<UUID>()
        return events
            .flatMap { attachedTasks(for: $0) }
            .filter { seen.insert($0.id).inserted }
    }

    /// 이 날 화면에 보이는 할 일 전체. 상단 요약 개수가 이 값을 따른다.
    private var visibleTaskCount: Int {
        nestedTasks.count + sectionTasks.count
    }

    private var sectionTasks: [ResolvedTask] {
        let nestedIDs = Set(nestedTasks.map(\.id))

        return resolvedTasks
            .filter { !nestedIDs.contains($0.id) }
            // 마감까지 지난 것은 맨 아래 「기한 지난 할 일」이 전담한다.
            // 그 섹션은 **선택 날짜와 무관하게 늘 보이므로**, 여기서 빼도 화면에서 사라지지 않는다.
            // 반대로 여기 두면 날짜를 옮길 때마다 나타났다 사라져 추적이 안 되고,
            // 마감일을 고른 순간에는 같은 항목이 두 섹션에 동시에 나온다.
            .filter { !$0.isMissed(now: now) }
            .filter(matchesSelectedDay)
            // 미완료 먼저, 완료는 아래. 그리드와 같은 규칙이다. (ResolvedTask.listOrder)
            .sorted { ResolvedTask.listOrder($0, $1, isCompleted: orderingCompletion) }
    }

    private func matchesSelectedDay(_ resolved: ResolvedTask) -> Bool {
        let selected = manager.selectedDate

        if let startDeadline = resolved.startDeadline,
           manager.calendar.isDate(startDeadline, inSameDayAs: selected) {
            return true
        }
        if let due = resolved.effectiveDueAt,
           manager.calendar.isDate(due, inSameDayAs: selected) {
            return true
        }
        // 시작 시점을 놓친 것은 오늘 화면에서 계속 보여야 한다.
        // 판정은 `isAtRisk` 하나만 쓴다 — 마감까지 지난 것은 이미 걸러져 들어오지 않는다.
        if resolved.isAtRisk(now: now), manager.calendar.isDateInToday(selected) {
            return true
        }
        return false
    }

    /// 마감까지 지났는데 아직 끝내지 않은 할 일. (명세서 9.4 「놓침」)
    ///
    /// **선택 날짜와 무관하다.** 어느 날짜를 보든 같은 목록이다.
    /// 달을 넘기면 그리드에서 사라지고 알림도 다 울려 버려, 시간이 갈수록 안 보이게 되는
    /// 항목들이다. 여기가 마지막으로 붙잡아 두는 자리다.
    ///
    /// 오래 지난 것이 위로 온다 — 마감이 이른 순. 가장 오래 방치된 것을 먼저 보여준다.
    private var missedTasks: [ResolvedTask] {
        resolvedTasks
            .filter { $0.isMissed(now: now) }
            .sorted { lhs, rhs in
                let l = lhs.effectiveDueAt ?? .distantPast
                let r = rhs.effectiveDueAt ?? .distantPast
                if l != r { return l < r }
                return lhs.task.title < rhs.task.title
            }
    }

    /// 부모 일정 식별자 → 딸린 할 일. 2계층에서 일정 아래 들여쓰기로 붙인다.
    private var tasksByParent: [String: [ResolvedTask]] {
        Dictionary(grouping: resolvedTasks.filter(\.isAttached)) { $0.task.parentEventID ?? "" }
            .mapValues { group in
                group.sorted { ($0.effectiveDueAt ?? .distantFuture) < ($1.effectiveDueAt ?? .distantFuture) }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1계층 「오늘 시작」 — 최상단 고정. 0개면 블록 자체가 사라진다. (명세서 5.2)
            // 늘 같은 높이라 아래 시작 위치가 흔들리지 않는다.
            TodayStartSection(tasks: resolvedTasks, now: now)

            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    eventSection
                    sectionDivider
                    taskSection

                    // **이 섹션만 「비면 숨김」이다. 통일이 안 된 것이 아니라 의도다.**
                    //
                    // 「일정」·「할 일」은 비어도 문구를 띄운다. 그 자리에 무엇이 오는지를
                    // 늘 알려야 하기 때문이다. 반면 기한 지난 할 일은 **없는 것이 정상 상태**라,
                    // 「기한 지난 할 일이 없습니다.」가 늘 떠 있으면 화면만 복잡해진다.
                    //
                    // 맨 아래에 두는 이유도 같다. 나타나고 사라져도 위쪽이 밀리지 않는다.
                    if !missedTasks.isEmpty {
                        sectionDivider
                        missedSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                // 카드 아래 빈 곳을 누르면 고른 것이 풀린다.
                //
                // **`.top` 이 아니라 `.topLeading` 이다.** `.top` 은 가로로 **가운데**를
                // 뜻한다. 항목이 없는 날에는 안쪽 VStack 이 글자 폭만큼만 좁아지는데,
                // 그때 이 프레임이 그것을 한가운데로 밀어 「📅 일정」 머리글이
                // 혼자 가운데 정렬된 것처럼 보였다.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { selection.clear() }
            }
        }
        .onReceive(clock) { now = $0 }
        .onAppear { orderedCompletion = completionSignature }
        .onChange(of: completionSignature) { _, current in followCompletion(current) }
        .task(id: manager.displayedMonth) { syncLinks() }
        // 캘린더 앱 등에서 일정이 바뀌면 CalendarManager 가 토큰을 올린다.
        // 뷰 본문이 아니라 여기서 정리하므로 렌더링 중 저장이 일어나지 않는다.
        .onChange(of: manager.storeChangeToken) { _, _ in syncLinks() }
        .sheet(isPresented: $isAddingItem) {
            AddSheetView(manager: manager, defaultDate: manager.selectedDate)
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(
                task: task,
                defaultDueDate: task.dueAt ?? manager.selectedDate,
                manager: manager
            )
        }
        .sheet(item: $eventToOpen) { dayEvent in
            EventEditorView(
                manager: manager,
                event: dayEvent.primary,
                // 삭제는 묶음 전체가 대상이다. 대표 하나만 넘기면 나머지가 남는다. (BL-048)
                groupedEvents: dayEvent.events,
                defaultDate: manager.selectedDate
            )
        }
        // 그리드에서 날짜를 더블클릭한 경우. 「일정 추가」 버튼과 같은 시트를 쓴다.
        .sheet(item: addDateBinding) { wrapped in
            AddSheetView(manager: manager, defaultDate: wrapped.date)
        }
        // 그리드에서 기간을 드래그한 경우. 시작일·종료일이 채워진 채 열린다.
        .sheet(item: addRangeBinding) { wrapped in
            AddSheetView(
                manager: manager,
                defaultDate: wrapped.range.lowerBound,
                defaultEndDate: wrapped.range.upperBound
            )
        }
        // 그리드에서 할 일을 클릭한 경우.
        .sheet(item: $taskToOpen) { task in
            TaskEditorView(
                task: task,
                defaultDueDate: task.dueAt ?? manager.selectedDate,
                manager: manager
            )
        }
        // 일정 삭제는 반드시 확인을 거친다. 할 일 삭제(우클릭 → 바로 지움)와 다르게
        // 동작하는 것은 의도다. 이유는 `eventDeletionAlert` 주석에 있다.
        .eventDeletionAlert(
            $deletionRequest,
            manager: manager,
            onFailure: { eventErrorMessage = $0 }
        )
        .alert(
            "일정을 지우지 못했어요",
            isPresented: Binding(
                get: { eventErrorMessage != nil },
                set: { if !$0 { eventErrorMessage = nil } }
            )
        ) {
            Button("확인") { eventErrorMessage = nil }
        } message: {
            Text(eventErrorMessage ?? "")
        }
        .alert("연결된 일정을 찾지 못했어요", isPresented: detachedAlertBinding) {
            Button("확인") { detachedNotices = [] }
        } message: {
            Text(detachedMessage)
        }
    }

    /// `sheet(item:)` 에 쓰기 위해 날짜를 Identifiable 로 감싼다.
    private struct AddDate: Identifiable {
        let date: Date
        var id: TimeInterval { date.timeIntervalSinceReferenceDate }
    }

    private struct AddRange: Identifiable {
        let range: ClosedRange<Date>
        var id: TimeInterval { range.lowerBound.timeIntervalSinceReferenceDate }
    }

    private var addRangeBinding: Binding<AddRange?> {
        Binding(
            get: { addRange.map(AddRange.init) },
            set: { addRange = $0?.range }
        )
    }

    private var addDateBinding: Binding<AddDate?> {
        Binding(
            get: { addOnDate.map(AddDate.init) },
            set: { addOnDate = $0?.date }
        )
    }

    // MARK: - 2계층: 일정 + 딸린 할 일

    private var eventSection: some View {
        PanelSection(
            title: "일정",
            systemImage: "calendar",
            isEmpty: events.isEmpty,
            emptyText: "일정이 없습니다."
        ) {
            ForEach(events) { dayEvent in
                eventCard(dayEvent)
            }
        }
    }

    /// 일정 카드 하나.
    ///
    /// 딸린 할 일이 없으면 카드 전체가 하나의 클릭 대상이라 카드째 밝아진다.
    /// 딸린 할 일이 있으면 **밝아지는 범위를 눌리는 범위에 맞춰 쪼갠다** —
    /// 일정 영역과 할 일 줄이 각각 따로 밝아지고, 동시에 밝아지지 않는다.
    @ViewBuilder
    private func eventCard(_ dayEvent: DayEvent) -> some View {
        let attached = attachedTasks(for: dayEvent)

        let keys = dayEvent.occurrenceKeys

        if attached.isEmpty {
            PanelCard(inset: CardMetrics.borderGap) {
                eventHeaderRegion(dayEvent, keys: keys, attached: attached)
            }
        } else {
            PanelCard(inset: CardMetrics.borderGap) {
                // 사이 간격을 두지 않는다. 간격이 남으면 그 띠가 어느 영역에도 속하지 않아
                // 커서를 세로로 옮길 때 하이라이트가 끊긴다.
                // 간격은 위아래 영역의 여백으로 흡수시킨다.
                VStack(alignment: .leading, spacing: 0) {
                    eventHeaderRegion(dayEvent, keys: keys, attached: attached)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(attached) { resolved in
                            HoverRegion(
                                onSelect: { selection.select(task: resolved, among: resolvedTasks) },
                                onOpen: { editingTask = resolved.task }
                            ) {
                                TaskRow(
                                    resolved: resolved,
                                    isNested: true,
                                    now: now,
                            onEdit: { editingTask = resolved.task },
                                    onDelete: { delete(resolved) }
                                )
                            }
                        }
                    }
                    // 구분선은 레이아웃 자리를 차지하지 않게 겹쳐 그린다.
                    // 자리를 차지하면 그만큼 다시 빈틈이 생긴다.
                    .overlay(alignment: .top) {
                        Divider().allowsHitTesting(false)
                    }
                }
            }
        }
    }

    /// 일정 줄. 한 번 눌러 고르고, 두 번 눌러 편집하고, 우클릭하면 메뉴가 뜬다.
    ///
    /// 딸린 할 일이 있든 없든 **같은 것**을 쓴다. 한쪽에만 메뉴가 붙는 일이 없도록.
    private func eventHeaderRegion(
        _ dayEvent: DayEvent,
        keys: [String],
        attached: [ResolvedTask]
    ) -> some View {
        HoverRegion(
            onSelect: { selectEvent(keys) },
            onOpen: { eventToOpen = dayEvent }
        ) {
            EventRow(dayEvent: dayEvent, day: manager.selectedDate)
        }
        .contextMenu { eventMenu(dayEvent, attached: attached) }
    }

    /// 일정 카드의 우클릭 메뉴. 할 일 행에만 있던 것을 여기에도 맞췄다.
    ///
    /// 읽기 전용 캘린더(구독·공휴일 등)는 고칠 수도 지울 수도 없다. 그때는 할 수 있는
    /// 것만 내놓는다 — 비활성 항목만 뜨는 메뉴는 허탈하고, 아무것도 안 뜨면 고장으로 읽힌다.
    /// 판정은 `CalendarManager.isEditable(_:)` 을 그대로 쓴다. (「일정 보기」 시트가 쓰는 것)
    @ViewBuilder
    private func eventMenu(_ dayEvent: DayEvent, attached: [ResolvedTask]) -> some View {
        if manager.isEditable(dayEvent.primary) {
            Button("편집") { eventToOpen = dayEvent }
            Divider()
            Button("삭제", role: .destructive) {
                deletionRequest = EventDeletionRequest(
                    events: dayEvent.events,
                    attachedTaskCount: attached.count
                )
            }
        } else {
            Button("일정 보기") { eventToOpen = dayEvent }
        }
    }

    /// 이 일정에 딸린 할 일. 중복 등록분 중 어느 캘린더의 것을 골랐든 찾아낸다.
    private func attachedTasks(for dayEvent: DayEvent) -> [ResolvedTask] {
        let identifiers = Set(dayEvent.events.compactMap(\.eventIdentifier))
        // 일정 카드 안 딸린 할 일도 같은 순서다. 한 패널 안에서 순서 규칙이 둘이면 안 된다.
        return identifiers.flatMap { tasksByParent[$0] ?? [] }
            .sorted { ResolvedTask.listOrder($0, $1, isCompleted: orderingCompletion) }
    }

    // MARK: - 3계층: 이 날의 할 일

    private var taskSection: some View {
        PanelSection(
            title: "할 일",
            systemImage: "checklist",
            isEmpty: sectionTasks.isEmpty,
            emptyText: "할 일이 없습니다."
        ) {
            ForEach(sectionTasks) { resolved in
                // 일정 카드와 같은 방식이다. 하이라이트는 카드 안쪽만 칠한다.
                PanelCard(inset: CardMetrics.borderGap) {
                    HoverRegion(
                        onSelect: { selection.select(task: resolved, among: resolvedTasks) },
                        onOpen: { editingTask = resolved.task }
                    ) {
                        TaskRow(
                            resolved: resolved,
                            showsParentContext: true,
                            now: now,
                            onEdit: { editingTask = resolved.task },
                            onDelete: { delete(resolved) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 4계층: 기한 지난 할 일 (명세서 9.4 「놓침」)

    private var missedSection: some View {
        PanelSection(
            title: "기한 지난 할 일",
            systemImage: "exclamationmark.circle",
            isEmpty: false,
            emptyText: ""
        ) {
            ForEach(missedTasks) { resolved in
                // 「할 일」 섹션과 같은 카드·호버·클릭 경로를 쓴다. 이 섹션만의 구조를 따로 만들지 않는다.
                PanelCard(inset: CardMetrics.borderGap) {
                    HoverRegion(
                        onSelect: { selection.select(task: resolved, among: resolvedTasks) },
                        onOpen: { editingTask = resolved.task }
                    ) {
                        TaskRow(
                            resolved: resolved,
                            showsParentContext: true,
                            now: now,
                            onEdit: { editingTask = resolved.task },
                            onDelete: { delete(resolved) }
                        )
                    }
                }
            }
        }
    }

    /// 섹션 사이를 가르는 옅은 선.
    ///
    /// **섹션을 박스로 묶지 않는다.** 항목이 이미 테두리 있는 카드라서
    /// 섹션까지 박스로 두르면 테두리가 이중이 되어 더 복잡해 보인다.
    ///
    /// 선은 얇고 옅게 둔다. 진하면 화면이 조각난 인상이 된다.
    /// 위아래 여백은 바깥 `VStack` 의 간격 14pt 가 그대로 맡는다.
    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(height: 1)
    }

    // MARK: - 머리글

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(dateTitle)
                    .font(.title3.bold())
                Spacer(minLength: 8)
                Button {
                    isAddingItem = true
                } label: {
                    Label("일정 추가", systemImage: "plus")
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.14))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                        )
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("일정이나 할 일 추가")
            }

            Text("일정 \(events.count)개 · 할 일 \(visibleTaskCount)개")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - 동작

    /// 부모 일정 상태를 저장값에 반영한다. 화면을 그리는 중이 아니라 여기서만 쓴다.
    private func syncLinks() {
        let detached = TaskLinkMaintenance.sync(tasks: allTasks, manager: manager)
        // 부모 이동에 따른 마감 갱신과 독립 전환도 즉시 디스크에 쓴다.
        saver.commit(modelContext)
        if !detached.isEmpty { detachedNotices = detached }
    }

    /// 우측 패널은 이미 고른 날짜만 보여주는 좁은 범위라 여기서는 강조하지 않는다.
    /// 고르기는 그리드 강조로 드러난다.
    private func selectEvent(_ occurrenceKeys: [String]) {
        selection.select(occurrenceKeys: occurrenceKeys, among: resolvedTasks)
    }

    private func delete(_ resolved: ResolvedTask) {
        modelContext.delete(resolved.task)
        saver.commit(modelContext)
    }

    private var detachedAlertBinding: Binding<Bool> {
        Binding(
            get: { !detachedNotices.isEmpty },
            set: { if !$0 { detachedNotices = [] } }
        )
    }

    /// 어떤 할 일이 왜 전환됐는지 밝힌다. 조용히 바뀌면 안 된다. (명세서 4.2)
    private var detachedMessage: String {
        let list = detachedNotices.map(\.summary).joined(separator: "\n")
        return "\(list)\n\n연결은 그대로 두고 마지막 마감으로 보여주고 있어요. 일정이 정말 지워졌다면 할 일을 열어 「특정 날짜」로 바꿔주세요."
    }

    private var dateTitle: String {
        Self.dateFormatter.string(from: manager.selectedDate)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .startlineDisplay
        formatter.dateFormat = "yyyy년 M월 d일 (E)"
        return formatter
    }()
}

/// 일정 한 행 — [시각] [제목] [소속 캘린더명]
struct EventRow: View {
    let dayEvent: DayEvent
    /// 이 행이 놓인 날짜. 여러 날에 걸친 일정의 시각 표기에 쓴다.
    let day: Date

    private var event: EKEvent { dayEvent.primary }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendar.map { Color(cgColor: $0.cgColor) } ?? .gray)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(timeText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(event.title ?? "(제목 없음)")
                    .font(.body)

                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                calendarLabel
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 중복 등록된 일정은 어느 캘린더들에 있는지 모두 보여준다.
    private var calendarLabel: some View {
        HStack(spacing: 4) {
            ForEach(Array(dayEvent.events.enumerated()), id: \.offset) { _, source in
                HStack(spacing: 3) {
                    Circle()
                        .fill(source.calendar.map { Color(cgColor: $0.cgColor) } ?? .gray)
                        .frame(width: 6, height: 6)
                    Text(source.calendar?.title ?? "(캘린더 없음)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 종일이면 "종일", 아니면 "HH:mm – HH:mm".
    /// 이 날 이전에 시작했거나 이후까지 이어지면 말줄임표로 표시한다.
    private var timeText: String {
        guard let start = event.startDate else { return "-" }
        if event.isAllDay { return "종일" }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let end = event.endDate ?? start

        let startText = start < dayStart ? "…" : Self.timeFormatter.string(from: start)
        let endText = end >= dayEnd ? "…" : Self.timeFormatter.string(from: end)
        return "\(startText) – \(endText)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .startlineDisplay
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// 우측 패널의 한 섹션. 머리글 + 내용, 비어 있으면 빈 상태 문구.
///
/// **「일정」과 「할 일」이 같은 규칙을 쓴다.** 예전에는 「일정」만 「일정이 없습니다.」를
/// 띄우고 「할 일」은 비면 섹션째 사라졌다. 같은 자리의 두 섹션이 다르게 굴어
/// 어느 쪽이 원래 규칙인지 알 수 없었다.
///
/// **폭을 항상 채운다.** 안 채우면 항목이 없는 날에 이 뷰가 글자 폭만큼만 좁아지고,
/// 바깥 프레임이 그것을 가운데로 밀어 머리글만 혼자 가운데 정렬된 것처럼 보인다.
private struct PanelSection<Content: View>: View {
    let title: String
    let systemImage: String
    let isEmpty: Bool
    let emptyText: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: title, systemImage: systemImage)

            if isEmpty {
                EmptyNote(text: emptyText)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
