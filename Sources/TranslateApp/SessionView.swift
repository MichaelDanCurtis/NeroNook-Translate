import AppKit
import SwiftUI
import TranslateAudio
import TranslateLive

/// The session window: what you say, what the other person would read and hear.
struct SessionView: View {
    @ObservedObject var session: LiveSession
    @State private var devices = AudioDevices.inputs()
    @State private var namesText = ""
    @State private var transcriptText = ""
    @State private var installing = false
    @State private var installMessage = ""

    var body: some View {
        HStack(spacing: 0) {
            settings.frame(width: 320).padding(16)
            Divider()
            captions.padding(16)
        }
        .onAppear {
            namesText = session.configuration.names.joined(separator: ", ")
            transcriptText = session.configuration.reference?.transcript ?? ""
        }
    }

    private var busy: Bool { if case .preparing = session.state { return true }; if case .stopping = session.state { return true }; return false }
    private var listening: Bool { if case .listening = session.state { return true }; return false }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Translate").font(.title2.weight(.semibold))
            Text("Self-test: speak, read the captions, and hear yourself in the other language.").font(.callout).foregroundStyle(.secondary)

            Group {
                Text("Languages").font(.headline)
                Picker("I speak", selection: $session.configuration.sourceLanguage) { ForEach(Languages.supported, id: \.self) { Text(Languages.name($0)).tag($0) } }
                Picker("They hear", selection: $session.configuration.targetLanguage) { ForEach(Languages.supported, id: \.self) { Text(Languages.name($0)).tag($0) } }
                HStack {
                    Button(installing ? "Installing…" : "Install speech assets") { install() }.disabled(installing || listening)
                    if !installMessage.isEmpty { Text(installMessage).font(.caption).foregroundStyle(.secondary) }
                }
            }.disabled(listening || busy)

            Group {
                Text("Microphone").font(.headline)
                Picker("Input", selection: Binding(get: { session.configuration.microphoneUID ?? "" }, set: { session.configuration.microphoneUID = $0.isEmpty ? nil : $0 })) {
                    Text("System default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                }
                LevelBar(level: session.inputLevel)
            }.disabled(listening || busy)

            Group {
                Text("Your voice").font(.headline)
                HStack {
                    Button("Choose reference clip…") { chooseReference() }
                    Text(session.configuration.reference?.url.lastPathComponent ?? "none (captions only)").font(.caption).lineLimit(1).truncationMode(.middle)
                }
                TextField("The exact words in the clip", text: $transcriptText, axis: .vertical).lineLimit(2...4)
                    .onChange(of: transcriptText) { _, text in session.configuration.reference?.transcript = text }
                Toggle("Hear the translation through the speakers", isOn: $session.configuration.hear)
                LevelBar(level: session.outputLevel)
            }.disabled(listening || busy)

            Group {
                Text("Names").font(.headline)
                TextField("Participant names, comma-separated", text: $namesText)
                    .onChange(of: namesText) { _, text in session.configuration.names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            }.disabled(listening || busy)

            Spacer()
            Text(session.engineStatus).font(.caption).foregroundStyle(.secondary)
            if session.synthesis.speaking || session.synthesis.queued > 0 {
                Text("Speaking · \(session.synthesis.queued) queued" + (session.synthesis.lastFirstAudioMs.map { " · first audio \($0) ms" } ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if listening {
                    Button("Stop") { Task { await session.stop() } }.keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button(busy ? "Preparing…" : "Start listening") { Task { await session.start() } }.keyboardShortcut(.return, modifiers: [.command]).disabled(busy)
                }
                Spacer()
                stateLabel
            }
        }
    }

    private var stateLabel: some View {
        Group {
            switch session.state {
            case .idle: Text("Idle").foregroundStyle(.secondary)
            case .preparing(let step): Text(step).foregroundStyle(.secondary)
            case .listening: Label("Listening", systemImage: "mic.fill").foregroundStyle(.green)
            case .stopping: Text("Stopping…").foregroundStyle(.secondary)
            case .failed(let message): Text(message).foregroundStyle(.red).lineLimit(3).font(.caption)
            }
        }.font(.callout)
    }

    private var captions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(Languages.name(session.configuration.sourceLanguage)) → \(Languages.name(session.configuration.targetLanguage))").font(.headline)
                Spacer()
                Text("\(session.captions.count) phrases").font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.captions) { caption in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(caption.original).font(.body)
                                if let translated = caption.translated { Text(translated).font(.body).foregroundStyle(.teal) }
                                else if let error = caption.error { Text(error).font(.caption).foregroundStyle(.red) }
                                else { Text("translating…").font(.caption).foregroundStyle(.secondary) }
                            }
                            .id(caption.id)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                        if !session.partial.isEmpty {
                            Text(session.partial).font(.body).foregroundStyle(.secondary).italic().id("partial")
                        }
                    }
                }
                .onChange(of: session.captions.count) { _, _ in if let last = session.captions.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: session.partial) { _, _ in if !session.partial.isEmpty { proxy.scrollTo("partial", anchor: .bottom) } }
            }
        }
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Pick 3–30 seconds of the speaker, and type the exact words below."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sibling = url.deletingPathExtension().appendingPathExtension("txt")
        let transcript = (try? String(contentsOf: sibling, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? transcriptText
        transcriptText = transcript
        session.configuration.reference = VoiceReference(url: url, transcript: transcript)
    }

    private func install() {
        installing = true; installMessage = ""
        let locale = Locale(identifier: Languages.speechLocale(session.configuration.sourceLanguage))
        Task {
            do { try await AppleRecognitionStream.installAssets(locale: locale); installMessage = "\(locale.identifier) installed" }
            catch { installMessage = "\(error)" }
            installing = false
        }
    }
}

struct LevelBar: View {
    var level: Float
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3).fill(level > 0.9 ? Color.red : Color.green).frame(width: geometry.size.width * CGFloat(min(1, max(0, level))))
            }
        }.frame(height: 6)
    }
}
