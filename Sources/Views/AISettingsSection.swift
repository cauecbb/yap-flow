import SwiftUI

/// Who transcribes and who cleans up, plus a key and model fields for each
/// service those choices use.
struct AISettingsSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("AI")
            Card(padding: Theme.s2) {
                VStack(spacing: 0) {
                    PickerRow(
                        title: "Transcription",
                        subtitle: transcriptionSubtitle,
                        selection: $app.transcriptionProvider,
                        options: TranscriptionProvider.allCases,
                        label: \.title
                    )

                    divider

                    PickerRow(
                        title: "Cleanup",
                        subtitle: cleanupSubtitle,
                        selection: $app.cleanupProvider,
                        options: CleanupProvider.allCases,
                        label: \.title
                    )
                    .disabled(geminiCleansUp)

                    ForEach(servicesInUse) { service in
                        divider
                        ServiceRow(service: service, roles: roles(for: service))
                    }

                    if let error = app.cloud.lastError ?? app.cleanup.lastError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.recording)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.s3)
                            .padding(.vertical, Theme.s2)
                    }
                }
            }
        }
    }

    private var divider: some View {
        Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
    }

    private var geminiCleansUp: Bool { app.transcriptionProvider == .gemini }

    private var transcriptionSubtitle: String {
        switch app.transcriptionProvider {
        case .gemini:
            return "Streams while you talk. Cleans up and handles mixed languages on its own."
        case .onDevice:
            return "Apple's speech model, on your Mac. One language at a time."
        case .openai, .groq, .custom:
            return "Audio goes to \(app.transcriptionProvider.title) on release. On-device if it fails."
        }
    }

    private var cleanupSubtitle: String {
        if geminiCleansUp { return "Gemini already cleans up." }
        switch app.cleanupProvider {
        case .off:
            return "Pastes the transcript as heard."
        case .apple:
            return app.appleCleanup.isAvailable
                ? "On your Mac, with Apple Intelligence."
                : "Requires Apple Intelligence, enabled in System Settings."
        case .openai, .anthropic, .groq, .gemini, .custom:
            return "Removes filler, fixes punctuation, formats lists."
        }
    }

    /// Each service the two choices use, once, in the order they appear.
    private var servicesInUse: [AIService] {
        var services: [AIService] = []
        if let service = app.transcriptionProvider.service { services.append(service) }
        if !geminiCleansUp, let service = app.cleanupProvider.service, !services.contains(service) {
            services.append(service)
        }
        return services
    }

    private func roles(for service: AIService) -> [AIRole] {
        var roles: [AIRole] = []
        if app.transcriptionProvider.service == service { roles.append(.transcription) }
        if !geminiCleansUp, app.cleanupProvider.service == service { roles.append(.cleanup) }
        return roles
    }
}

private struct PickerRow<Option: Hashable & Identifiable>: View {
    let title: String
    let subtitle: String
    @Binding var selection: Option
    let options: [Option]
    let label: KeyPath<Option, String>

    var body: some View {
        HStack(spacing: Theme.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.s3)
            Picker("", selection: $selection) {
                ForEach(options) { option in
                    Text(option[keyPath: label]).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 168)
        }
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s2 + 2)
    }
}

/// A service's key, and the model it uses for each role. Blank model fields
/// mean the default, shown as the placeholder.
private struct ServiceRow: View {
    let service: AIService
    let roles: [AIRole]

    @Environment(AppState.self) private var app
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(service.title) API key").font(.system(size: 13, weight: .medium))
                    Text(app.keys.has(service) ? "Saved in your keychain." : service.keyHint)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.s3)
                if app.keys.has(service) {
                    Button("Remove") { app.keys.remove(service) }
                } else {
                    SecureField("Paste key", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if service == .custom {
                DefaultsField(
                    title: "Base URL", key: AIConfig.customBaseURLKey,
                    placeholder: "https://openrouter.ai/api/v1"
                )
            }
            ForEach(roles) { role in
                DefaultsField(
                    title: role == .transcription ? "Transcription model" : "Cleanup model",
                    key: AIConfig.modelKey(service, role),
                    placeholder: AIConfig.defaultModel(service, role).isEmpty
                        ? "Model ID" : AIConfig.defaultModel(service, role)
                )
            }
        }
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s2 + 2)
    }

    private func save() {
        app.keys.save(draft, for: service)
        draft = ""
    }
}

/// A text field written straight to UserDefaults, where AIConfig reads it.
private struct DefaultsField: View {
    let title: String
    let placeholder: String
    @AppStorage private var value: String

    init(title: String, key: String, placeholder: String) {
        self.title = title
        self.placeholder = placeholder
        _value = AppStorage(wrappedValue: "", key)
    }

    var body: some View {
        HStack(spacing: Theme.s3) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.s3)
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 220)
        }
    }
}
