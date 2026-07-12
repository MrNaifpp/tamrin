import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var store: TamrinStore?

    var body: some View {
        Group {
            if let store {
                RootView(store: store)
            } else {
                ProgressView().controlSize(.large)
                    .task {
                        let newStore = TamrinStore(context: modelContext)
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("-TamrinDemo"), newStore.profile == nil {
                            newStore.saveProfile(name: "فارس")
                            _ = newStore.join(code: "MOVE24")
                        } else if (["-TamrinCreateFlow", "-TamrinScheduleFlow", "-TamrinDaysFlow", "-TamrinComposerFlow", "-TamrinCapacityFlow", "-TamrinTemplatesFlow", "-TamrinMembersFlow"].contains(where: ProcessInfo.processInfo.arguments.contains)), newStore.profile == nil {
                            newStore.saveProfile(name: "فارس")
                        }
                        if ProcessInfo.processInfo.arguments.contains("-TamrinAdminExperience") {
                            newStore.experienceMode = .admin
                        }
                        if ProcessInfo.processInfo.arguments.contains("-TamrinRegisteredDemo"),
                           let occurrence = newStore.teamOccurrences.first,
                           newStore.myRegistration(for: occurrence) == nil {
                            newStore.register(for: occurrence)
                        }
                        #endif
                        store = newStore
                    }
            }
        }
        .onOpenURL { url in
            guard url.scheme == "tamrin", url.host == "join",
                  let code = url.pathComponents.last else { return }
            _ = store?.join(code: code)
        }
        .tamrinTypography()
    }
}

struct RootView: View {
    @Bindable var store: TamrinStore

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-TamrinProfileFlow") {
                ProfileSetupView(store: store)
            } else if ProcessInfo.processInfo.arguments.contains("-TamrinComposerFlow") {
                CreateExerciseFlow(store: store)
            } else if store.profile == nil {
                ProfileSetupView(store: store)
            } else if store.teams.isEmpty {
                WelcomeView(store: store, startInCreateFlow: ["-TamrinCreateFlow", "-TamrinScheduleFlow", "-TamrinDaysFlow", "-TamrinComposerFlow", "-TamrinCapacityFlow", "-TamrinTemplatesFlow", "-TamrinMembersFlow"].contains(where: ProcessInfo.processInfo.arguments.contains))
                    .task { store.ensureDemoExperience() }
            } else {
                HomeView(store: store)
            }
            #else
            if store.profile == nil {
                ProfileSetupView(store: store)
            } else if store.teams.isEmpty {
                WelcomeView(store: store)
                    .task { store.ensureDemoExperience() }
            } else {
                HomeView(store: store)
            }
            #endif
        }
        .animation(.snappy(duration: 0.35), value: store.profile?.id)
        .animation(.snappy(duration: 0.35), value: store.teams.count)
    }
}

#Preview {
    ContentView().modelContainer(for: [UserProfile.self, Team.self, Membership.self, TrainingPlan.self,
                                       Occurrence.self, Registration.self, PaymentMethod.self,
                                       PaymentRecord.self, Invite.self, AppNotification.self], inMemory: true)
}
