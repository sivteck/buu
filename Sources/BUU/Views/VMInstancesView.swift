import SwiftUI
import VirtualMacKit
import VirtualMacCore

struct VMInstancesView: View {
    @Environment(AppState.self) private var appState
    @State private var deleting: Machine?
    @State private var errorMessage: String?

    private var vm: VirtualMacController { appState.virtualMac }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VM Instances")
                        .font(.title2.weight(.semibold))
                    Text("Virtual machines stored on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    vm.refreshMachines()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh VM instances")
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.l)
            .background(.bar)

            Divider()

            if vm.machines.isEmpty {
                VStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("No virtual machines")
                        .font(.title3)
                    Text("Create a Mac Task and install its VM to see it here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(vm.machines, id: \.name) { machine in
                        HStack(spacing: Theme.Spacing.m) {
                            Image(systemName: "macwindow.on.rectangle")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.name)
                                    .font(.headline)
                                Text(profileName(for: machine))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(machine.cpu) CPU · \(machine.memoryGiB) GB · \(machine.diskGiB) GB")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(machine.installed ? "installed" : "incomplete")
                                .font(.caption)
                                .foregroundStyle(machine.installed ? Theme.Colors.success : Theme.Colors.warning)
                            Button("Delete…", role: .destructive) {
                                deleting = machine
                            }
                            .buttonStyle(.borderless)
                            .disabled(vm.vmState != "stopped" || vm.isBusy || vm.isInstalling)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.danger)
                    .padding(Theme.Spacing.m)
            }
        }
        .background(Theme.Colors.canvas)
        .onAppear { vm.refreshMachines() }
        .confirmationDialog(
            "Delete virtual machine?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            presenting: deleting
        ) { machine in
            Button("Delete \(machine.name)", role: .destructive) {
                do {
                    try vm.deleteMachine(name: machine.name)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { machine in
            Text("This permanently deletes \(machine.name)'s disk and hardware files. Its VM profile remains.")
        }
    }

    private func profileName(for machine: Machine) -> String {
        if let profile = appState.macTaskConfigurations.first(where: { $0.machineName == machine.name }) {
            return "Profile: \(profile.name)"
        }
        return "No matching profile"
    }
}
