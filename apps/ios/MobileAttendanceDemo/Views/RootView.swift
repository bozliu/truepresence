import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var didInitialize = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            TabView(selection: Binding(
                get: { model.selectedTab },
                set: { model.setSelectedTab($0) }
            )) {
                HomeView(model: model)
                    .tag(AppTab.home)
                    .tabItem {
                        Label("Home", systemImage: "house.fill")
                    }

                HistoryView(model: model)
                    .tag(AppTab.history)
                    .tabItem {
                        Label("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }

                ProfileView(model: model)
                    .tag(AppTab.profile)
                    .tabItem {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
            }

            if shouldShowOnboardingGate {
                CameraPermissionGateView(model: model)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .task {
            guard didInitialize == false else { return }
            didInitialize = true
            await model.initialize()
        }
        .onChange(of: scenePhase) { _, newPhase in
            model.setSceneIsActive(newPhase == .active)
            guard newPhase == .active else { return }
            Task {
                await model.ensureBootstrapIfPossible()
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { model.successDecision != nil },
                set: { isPresented in
                    if isPresented == false {
                        model.acknowledgeSuccessDecision()
                    }
                }
            )
        ) {
            if let decision = model.successDecision {
                SuccessResultView(model: model, decision: decision)
            }
        }
    }

    private var shouldShowOnboardingGate: Bool {
        model.permissionsReady == false || model.bootstrap == nil || model.linkedStudent == nil
    }
}
