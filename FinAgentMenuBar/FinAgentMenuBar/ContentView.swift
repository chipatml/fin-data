import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var manager = FinAgentDataManager.shared
    @StateObject private var apiManager = APIKeyManager.shared
    @StateObject private var gcsAuth = GCSAuth.shared
    @StateObject private var gcsSync = GCSSync.shared
    @StateObject private var driveAuth = GoogleDriveAuth.shared
    @StateObject private var driveSync = GoogleDriveSync.shared

    // Shared credential inputs
    @State private var clientIdInput = ""
    @State private var secretInput = ""
    @State private var setupEnvironment: PlaidEnvironment = .production

    // New access token inputs
    @State private var tokenLabelInput = ""
    @State private var tokenValueInput = ""

    // Update-shared-credentials inputs
    @State private var updateClientIdInput = ""
    @State private var updateSecretInput = ""
    @State private var updateEnvironment: PlaidEnvironment = .production
    @State private var didSeedUpdateForm = false

    // Cloud Storage service-account key. Held only in this view until Save,
    // then wiped. The persisted copy is in the Keychain.
    @State private var serviceAccountJSON = ""
    @State private var replacementKeyJSON = ""
    @State private var importKeyFile = false
    @State private var importReplacementKey = false

    // Google Drive OAuth client inputs
    @State private var driveClientIdInput = ""
    @State private var driveClientSecretInput = ""

    @State private var status: String = ""

    private var canSaveShared: Bool {
        !clientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canUpdateCredentials: Bool {
        let clientId = updateClientIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = updateSecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasClientId = !clientId.isEmpty || apiManager.hasStoredClientId(for: updateEnvironment)
        let hasSecret = !secret.isEmpty || apiManager.hasStoredSecret(for: updateEnvironment)
        return hasClientId && hasSecret
    }
    private var canAddToken: Bool {
        !tokenLabelInput.isEmpty && !tokenValueInput.isEmpty
    }

    // Selectable background refresh intervals (seconds, label).
    private let intervalOptions: [(TimeInterval, String)] = [
        (60, "1 minute"),
        (300, "5 minutes"),
        (900, "15 minutes"),
        (1800, "30 minutes"),
        (3600, "1 hour"),
        (21600, "6 hours"),
        (86400, "1 day")
    ]

    private func intervalLabel(_ interval: TimeInterval) -> String {
        intervalOptions.first { $0.0 == interval }?.1 ?? "\(Int(interval))s"
    }

    // Selectable auto-rotate intervals (seconds, label).
    private let rotateOptions: [(TimeInterval, String)] = [
        (86400, "1 day"),
        (604800, "7 days"),
        (2592000, "30 days"),
        (7776000, "90 days")
    ]

    private func rotateIntervalLabel(_ interval: TimeInterval) -> String {
        rotateOptions.first { $0.0 == interval }?.1 ?? "\(Int(interval / 86400)) days"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !apiManager.hasSharedCredentials() {
                sharedCredentialsForm
            } else if !apiManager.isUnlocked {
                lockedView
            } else {
                ScrollView {
                    readyState
                }
                .frame(maxHeight: 460)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding()
        .frame(width: 320)
        .onAppear {
            if apiManager.hasSharedCredentials() {
                // Prompt once per launch; stays unlocked for the session.
                if !apiManager.isUnlocked {
                    Task { await unlockAndStart() }
                }
            } else {
                status = "No credentials set."
            }
        }
    }

    /// Authenticate (Touch ID when required), then start background work + pull.
    private func unlockAndStart() async {
        status = "Unlocking…"
        let ok = await apiManager.authenticate()
        status = ok ? "Unlocked" : "Locked"
        guard ok else { return }
        await manager.resumeAutoRotateIfEnabled()
        manager.resumeBackgroundIfEnabled()
        await manager.pullOnLaunchIfNeeded()
    }

    // MARK: - Locked state

    private var lockedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("Locked")
                .font(.headline)
            if let error = apiManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            Button("Unlock with Touch ID") {
                Task { await unlockAndStart() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Shared credentials entry

    private var sharedCredentialsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter your Plaid credentials")
                .font(.headline)

            environmentPicker(selection: $setupEnvironment)

            SecureField("client_id", text: $clientIdInput)
                .textFieldStyle(.roundedBorder)
            SecureField("secret", text: $secretInput)
                .textFieldStyle(.roundedBorder)

            Button("Save Credentials Securely") {
                commitTextInputs()
                DispatchQueue.main.async {
                    let clientId = clientIdInput
                    let secret = secretInput
                    let environment = setupEnvironment
                    Task {
                        await apiManager.storeSharedCredentials(
                            clientId: clientId,
                            secret: secret,
                            environment: environment
                        )
                        clientIdInput = ""
                        secretInput = ""
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSaveShared)

            if let error = apiManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            } else if !apiManager.statusMessage.isEmpty {
                Text(apiManager.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Stored securely using your Mac’s Secure Enclave.\nYou’ll add one or more access tokens next.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Ready state

    private var readyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(status, systemImage: "checkmark.shield.fill")
                .foregroundColor(.green)
                .font(.headline)

            Text("Plaid environment: \(apiManager.plaidEnvironment.displayName) (\(apiManager.plaidEnvironment.hostDescription))")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if apiManager.usesUnlabeledLegacySecret {
                Text("The saved secret is not tied to Sandbox or Production. Pulls still send it to Production until you choose the matching environment below and save that client_id and secret.")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            tokenList
            addTokenForm

            Divider()

            if let lastCall = manager.lastAPICall {
                Text("Last pull: \(lastCall.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = manager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button(manager.isRefreshing ? "Pulling…" : "Pull Plaid Data Now") {
                Task { await manager.performPeriodicAPICall() }
            }
            .disabled(manager.isRefreshing || manager.isResyncing || apiManager.tokenEntries.isEmpty)

            Button {
                Task { await manager.resyncHistory() }
            } label: {
                Label(manager.isResyncing ? "Re-syncing…" : "Re-sync Full History",
                      systemImage: "clock.arrow.circlepath")
            }
            .disabled(manager.isRefreshing || manager.isResyncing || apiManager.tokenEntries.isEmpty)
            .help("Resets saved sync cursors and re-fetches all available transaction history into the daily folders.")

            Button {
                manager.openDataFolder()
            } label: {
                Label("Open Data Folder", systemImage: "folder")
            }

            DisclosureGroup("Cloud Storage") {
                cloudStorageControls
            }
            .font(.subheadline)

            DisclosureGroup("Google Drive (legacy)") {
                driveControls
            }
            .font(.subheadline)

            DisclosureGroup("Background pulls") {
                backgroundControls
            }
            .font(.subheadline)

            DisclosureGroup("Token rotation") {
                rotationControls
            }
            .font(.subheadline)

            DisclosureGroup("Update client_id / secret") {
                updateCredentialsControls
            }
            .font(.subheadline)

            HStack {
                Button("Lock Now") {
                    apiManager.lock()
                }
                Spacer()
                Button("Reset All Credentials", role: .destructive) {
                    Task { await manager.resetAll() }
                }
            }
        }
    }

    // MARK: - Update shared credentials

    private var updateCredentialsControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sandbox and Production each keep their own client_id and secret. Paste both from the Plaid Dashboard for the environment selected here. A blank field keeps only a value already saved for that same environment. Changing the environment clears the secret. Tokens are preserved.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            environmentPicker(selection: $updateEnvironment)

            if !apiManager.hasStoredSecret(for: updateEnvironment) {
                Text(updateSecretHint)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !apiManager.hasStoredClientId(for: updateEnvironment), let legacy = apiManager.legacyClientIdLabel() {
                Text("An older unlabeled client_id is still on this Mac (\(legacy)). It is not sent. Paste the \(updateEnvironment.displayName) client_id if that is the one you want.")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("client_id", text: $updateClientIdInput)
                .textFieldStyle(.roundedBorder)
            if !updateClientIdInput.isEmpty {
                Text("client_id to save: \(PlaidCredentialText.clientIdLabel(PlaidCredentialText.normalized(updateClientIdInput)))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            SecureField("new secret (blank = keep)", text: $updateSecretInput)
                .textFieldStyle(.roundedBorder)
            if !updateSecretInput.isEmpty {
                Text("secret to save: len \(PlaidCredentialText.normalized(updateSecretInput).count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button("Update Credentials") {
                commitTextInputs()
                DispatchQueue.main.async {
                    let clientId = updateClientIdInput
                    let secret = updateSecretInput
                    let environment = updateEnvironment
                    Task {
                        await apiManager.updateSharedCredentials(
                            clientId: clientId,
                            secret: secret,
                            environment: environment
                        )
                        updateSecretInput = ""
                        updateClientIdInput = apiManager.currentClientId(for: environment) ?? clientId
                    }
                }
            }
            .disabled(!canUpdateCredentials)

            if let error = apiManager.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if apiManager.statusMessage.hasPrefix("Credentials updated") {
                Text(apiManager.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
        .onAppear {
            guard !didSeedUpdateForm else { return }
            updateEnvironment = apiManager.plaidEnvironment
            updateClientIdInput = apiManager.currentClientId(for: apiManager.plaidEnvironment) ?? ""
            didSeedUpdateForm = true
        }
        .onChange(of: updateEnvironment) { _, newEnvironment in
            guard didSeedUpdateForm else { return }
            updateClientIdInput = apiManager.currentClientId(for: newEnvironment) ?? ""
            updateSecretInput = ""
        }
    }

    /// Menu-bar text fields keep the typed value until they resign first responder.
    /// A click on Update would otherwise save the previous client_id or an empty secret.
    private func commitTextInputs() {
        for window in NSApp.windows {
            window.makeFirstResponder(nil)
        }
    }

    private var updateSecretHint: String {
        if updateEnvironment == .production && apiManager.usesUnlabeledLegacySecret {
            return "No Production-specific secret is saved. Until you save Sandbox or Production credentials here, pulls still send the previously saved secret to Production."
        }
        return "No secret is saved for \(updateEnvironment.displayName) yet. Paste that environment's secret. A secret saved for another environment is not reused."
    }

    private func environmentPicker(selection: Binding<PlaidEnvironment>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Environment")
                .font(.caption2)
                .foregroundColor(.secondary)
            Picker("Environment", selection: selection) {
                Text("Sandbox").tag(PlaidEnvironment.sandbox)
                Text("Production").tag(PlaidEnvironment.production)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("\(selection.wrappedValue.displayName) uses \(selection.wrappedValue.hostDescription).")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Cloud Storage controls

    private var cloudStorageControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !gcsAuth.isConfigured {
                cloudStorageSetup
            } else {
                cloudStorageConnected
            }
            if let error = gcsAuth.errorMessage ?? gcsSync.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private var cloudStorageSetup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste or import a GCP service account JSON key. It is stored in the Keychain, not in this repo. The bucket name is saved in settings.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $serviceAccountJSON)
                .font(.system(.caption2, design: .monospaced))
                .frame(minHeight: 72)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

            Button("Import JSON Key…") { importKeyFile = true }
                .font(.caption)

            TextField("bucket name", text: $gcsSync.bucketName)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 4) {
                Text("Prefix")
                    .font(.caption)
                TextField(GCSSync.defaultPrefix, text: $gcsSync.prefix)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            Text(objectLayoutCaption)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Save Service Account") {
                let json = serviceAccountJSON
                Task {
                    if await gcsAuth.save(json: json) {
                        serviceAccountJSON = ""
                        gcsSync.isEnabled = true
                        await gcsSync.syncAll(localRoot: manager.dataDirectoryURL)
                    }
                }
            }
            .disabled(serviceAccountJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || gcsSync.bucketName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .fileImporter(isPresented: $importKeyFile, allowedContentTypes: [.json]) { result in
            loadKeyFile(result, into: $serviceAccountJSON)
        }
    }

    private var cloudStorageConnected: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(gcsAuth.clientEmail ?? "Service account saved", systemImage: "externaldrive.fill.badge.checkmark")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)

            Toggle("Upload day files to Cloud Storage", isOn: $gcsSync.isEnabled)
                .font(.caption)

            TextField("bucket name", text: $gcsSync.bucketName)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 4) {
                Text("Prefix")
                    .font(.caption)
                TextField(GCSSync.defaultPrefix, text: $gcsSync.prefix)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            Text(objectLayoutCaption)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if gcsSync.pendingCount > 0 {
                Text("\(gcsSync.pendingCount) file(s) waiting to upload")
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else if let last = gcsSync.lastSync {
                Text("Last upload: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button(gcsSync.isSyncing ? "Uploading…" : "Sync All to Cloud Storage") {
                Task { await gcsSync.syncAll(localRoot: manager.dataDirectoryURL) }
            }
            .disabled(gcsSync.isSyncing || gcsSync.isMigrating || !gcsSync.isEnabled)
            .help("Upload every day file currently on disk, then retry anything still queued.")

            Button {
                Task { await gcsSync.checkStatus(localRoot: manager.dataDirectoryURL) }
            } label: {
                Label(gcsSync.isCheckingStatus ? "Checking…" : "Check Cloud Storage Status",
                      systemImage: "stethoscope")
            }
            .disabled(gcsSync.isCheckingStatus || gcsSync.isSyncing)

            if let status = gcsSync.status {
                cloudStatusReport(status)
            }

            DisclosureGroup("Update service account key") {
                Text("Replaces the Keychain copy. The bucket name is unchanged unless you edit it above.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $replacementKeyJSON)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(minHeight: 64)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Button("Import JSON Key…") { importReplacementKey = true }
                    .font(.caption)
                Button("Update Credential") {
                    let json = replacementKeyJSON
                    Task {
                        if await gcsAuth.save(json: json) {
                            replacementKeyJSON = ""
                        }
                    }
                }
                .disabled(replacementKeyJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.caption)
            .fileImporter(isPresented: $importReplacementKey, allowedContentTypes: [.json]) { result in
                loadKeyFile(result, into: $replacementKeyJSON)
            }

            Button(gcsSync.isMigrating ? "Copying…" : "Copy Drive files into the bucket") {
                Task { await gcsSync.importFromDrive(localRoot: manager.dataDirectoryURL) }
            }
            .disabled(gcsSync.isMigrating || gcsSync.isSyncing || !driveAuth.isConnected)
            .help("Uploads the local Data folder, then downloads any remaining day files from the connected Drive account.")

            Text("If Drive is already disconnected, upload the local folder instead:")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(GCSSync.migrationCommand(bucket: gcsSync.bucketName, prefix: gcsSync.prefix))
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Button("Remove Service Account", role: .destructive) {
                gcsAuth.clear()
                gcsSync.isEnabled = false
                gcsSync.reset()
                serviceAccountJSON = ""
                replacementKeyJSON = ""
            }
            .font(.caption)
        }
    }

    private var objectLayoutCaption: String {
        let bucket = gcsSync.bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = gcsSync.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let bucketLabel = bucket.isEmpty ? "BUCKET" : bucket
        let prefixLabel = prefix.isEmpty ? GCSSync.defaultPrefix : prefix
        return "gs://\(bucketLabel)/\(prefixLabel)/<YYYY-MM-DD>/<Label>.json"
    }

    private func loadKeyFile(_ result: Result<URL, Error>, into text: Binding<String>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let raw = try? String(contentsOf: url, encoding: .utf8) {
                text.wrappedValue = raw
                gcsAuth.errorMessage = nil
            } else {
                gcsAuth.errorMessage = "Could not read that file as UTF-8 text."
            }
        case .failure(let error):
            gcsAuth.errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func cloudStatusReport(_ status: GCSSync.Status) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = status.errorMessage {
                Label("Check failed", systemImage: "xmark.octagon.fill")
                    .font(.caption).bold()
                    .foregroundColor(.red)
                Text(error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if status.inSync {
                Label("IN SYNC", systemImage: "checkmark.seal.fill")
                    .font(.caption).bold()
                    .foregroundColor(.green)
                Text("\(status.remoteFiles) file(s) across \(status.remoteDays) day(s) in the bucket.")
            } else {
                Label("OUT OF SYNC", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).bold()
                    .foregroundColor(.orange)
                Text("Local \(status.localFiles) file(s) / \(status.localDays) day(s) · Cloud Storage \(status.remoteFiles) / \(status.remoteDays)")
                if !status.missing.isEmpty {
                    Text("• \(status.missing.count) missing from the bucket — “Sync All” uploads them")
                        .foregroundColor(.orange)
                }
                if !status.extra.isEmpty {
                    Text("• \(status.extra.count) extra in the bucket with no local file")
                }
                if status.queued > 0 {
                    Text("• \(status.queued) queued for the next upload")
                }
                ForEach((status.missing + status.extra).prefix(3), id: \.self) { path in
                    Text("   \(path)")
                        .foregroundColor(.secondary)
                }
            }
            Text("Checked \(status.checkedAt.formatted(date: .omitted, time: .shortened))")
                .foregroundColor(.secondary)
        }
        .font(.caption2)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    // MARK: - Google Drive controls

    private var driveControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !driveAuth.isConfigured {
                driveClientForm
            } else if !driveAuth.isConnected {
                Text("Sign in to pick the Google account that holds the data. Google shows its own login and consent page — this app never sees your password.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(driveAuth.isConnecting ? "Waiting for Google…" : "Sign in with Google") {
                    Task {
                        await driveAuth.connect()
                        if driveAuth.isConnected {
                            driveSync.isEnabled = true
                            await driveSync.syncAll(localRoot: manager.dataDirectoryURL)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(driveAuth.isConnecting)

                if let clientId = GoogleOAuthConfig.displayClientId {
                    Text("OAuth client \(Self.abbreviate(clientId))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Button("Change OAuth Client", role: .destructive) {
                    Task { await driveAuth.reset() }
                }
                .font(.caption)
            } else {
                driveConnectedControls
            }

            if let error = driveAuth.errorMessage ?? driveSync.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    /// Shorten a client id for display: `1234-abcd….apps.googleusercontent.com`
    /// is unreadable in a 320pt popover, and only the prefix identifies it.
    private static func abbreviate(_ clientId: String) -> String {
        let head = clientId.prefix(14)
        return clientId.count > 14 ? "\(head)…" : String(head)
    }

    /// One-time entry of the Google Cloud "Desktop app" OAuth client. Needed
    /// once because Google has no anonymous sign-in: the client id is what
    /// names this app on the consent screen. After this it's sign-in only.
    private var driveClientForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("One-time setup. In Google Cloud console, enable the Drive API and create an OAuth client of type **Desktop app**, then paste it here — after this, connecting is just a Google login.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("client ID (…apps.googleusercontent.com)", text: $driveClientIdInput)
                .textFieldStyle(.roundedBorder)
            SecureField("client secret", text: $driveClientSecretInput)
                .textFieldStyle(.roundedBorder)

            Button("Save OAuth Client") {
                driveAuth.configure(clientId: driveClientIdInput,
                                    clientSecret: driveClientSecretInput)
                driveClientSecretInput = ""
            }
            .disabled(driveClientIdInput.isEmpty || driveClientSecretInput.isEmpty)
        }
    }

    private var driveConnectedControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(driveAuth.statusMessage, systemImage: "checkmark.icloud")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Upload day files to Drive", isOn: $driveSync.isEnabled)
                .font(.caption)

            HStack(spacing: 4) {
                Text("Folder")
                    .font(.caption)
                TextField(GoogleDriveSync.defaultFolderName, text: $driveSync.folderName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            Text("Drive: \(driveSync.folderName)/<YYYY-MM-DD>/<Label>.json — share that folder with whoever reads it.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if driveSync.pendingCount > 0 {
                Text("\(driveSync.pendingCount) file(s) waiting to upload")
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else if let last = driveSync.lastSync {
                Text("Last upload: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button(driveSync.isSyncing ? "Uploading…" : "Sync All to Drive") {
                Task { await driveSync.syncAll(localRoot: manager.dataDirectoryURL) }
            }
            .disabled(driveSync.isSyncing || !driveSync.isEnabled)
            .help("Upload every day file currently on disk, then retry anything still queued.")

            Button {
                Task { await driveSync.checkStatus(localRoot: manager.dataDirectoryURL) }
            } label: {
                Label(driveSync.isCheckingStatus ? "Checking…" : "Check Drive Status",
                      systemImage: "stethoscope")
            }
            .disabled(driveSync.isCheckingStatus || driveSync.isSyncing)
            .help("Compare the local day files against what's actually in the Drive folder.")

            if let status = driveSync.status {
                driveStatusReport(status)
            }

            Button("Disconnect Google Drive", role: .destructive) {
                Task {
                    await driveAuth.disconnect()
                    driveSync.isEnabled = false
                    driveSync.reset()
                }
            }
            .font(.caption)
        }
    }

    /// IN SYNC / OUT OF SYNC verdict from the last status check.
    @ViewBuilder
    private func driveStatusReport(_ status: GoogleDriveSync.Status) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = status.errorMessage {
                Label("Check failed", systemImage: "xmark.octagon.fill")
                    .font(.caption).bold()
                    .foregroundColor(.red)
                Text(error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !status.folderExists {
                Label("Folder not in Drive yet", systemImage: "questionmark.folder")
                    .font(.caption).bold()
                    .foregroundColor(.orange)
                Text("“\(driveSync.folderName)” hasn’t been created — nothing has uploaded yet. \(status.localFiles) local file(s) waiting.")
                    .fixedSize(horizontal: false, vertical: true)
            } else if status.inSync {
                Label("IN SYNC", systemImage: "checkmark.seal.fill")
                    .font(.caption).bold()
                    .foregroundColor(.green)
                Text("\(status.driveFiles) file(s) across \(status.driveDays) day(s) in Drive.")
            } else {
                Label("OUT OF SYNC", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).bold()
                    .foregroundColor(.orange)
                Text("Local \(status.localFiles) file(s) / \(status.localDays) day(s) · Drive \(status.driveFiles) / \(status.driveDays)")
                if !status.missing.isEmpty {
                    Text("• \(status.missing.count) missing from Drive — “Sync All” uploads them")
                        .foregroundColor(.orange)
                }
                if !status.extra.isEmpty {
                    Text("• \(status.extra.count) extra in Drive with no local file")
                }
                if status.queued > 0 {
                    Text("• \(status.queued) queued for the next upload")
                }
                // A couple of examples make a mismatch far easier to chase.
                ForEach((status.missing + status.extra).prefix(3), id: \.self) { path in
                    Text("   \(path)")
                        .foregroundColor(.secondary)
                }
            }

            Text("Checked \(status.checkedAt.formatted(date: .omitted, time: .shortened))")
                .foregroundColor(.secondary)
        }
        .font(.caption2)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    // MARK: - Background pull controls

    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Refresh every", selection: $manager.backgroundInterval) {
                ForEach(intervalOptions, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .pickerStyle(.menu)

            if manager.isBackgroundActive {
                Label("Active (\(intervalLabel(manager.backgroundInterval)))",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Stop Background Pulls", role: .destructive) {
                    manager.stopBackgroundActivity()
                }
            } else {
                Button("Start Background Pulls") {
                    manager.startBackgroundActivity()
                }
                .disabled(apiManager.tokenEntries.isEmpty)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Token rotation controls

    private var rotationControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let last = manager.lastRotation {
                Text("Last rotated: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button(manager.isRotating ? "Rotating…" : "Rotate All Tokens Now") {
                Task { await manager.rotateAllTokens() }
            }
            .disabled(manager.isRotating || apiManager.tokenEntries.isEmpty)

            Picker("Auto-rotate every", selection: $manager.rotateInterval) {
                ForEach(rotateOptions, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .pickerStyle(.menu)

            if manager.isAutoRotateActive {
                Label("Auto-rotate active (\(rotateIntervalLabel(manager.rotateInterval)))",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Stop Auto-Rotate", role: .destructive) {
                    manager.stopAutoRotate()
                }
            } else {
                Button("Start Auto-Rotate") {
                    manager.startAutoRotate()
                }
                .disabled(apiManager.tokenEntries.isEmpty)
            }
        }
    }

    // MARK: - Token list + add form

    private var tokenList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Access tokens")
                .font(.subheadline).bold()

            if apiManager.tokenEntries.isEmpty {
                Text("None yet — add one below.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(apiManager.tokenEntries) { entry in
                    let snap = manager.snapshots.first { $0.id == entry.id }
                    DisclosureGroup {
                        if let snap {
                            snapshotDetail(snap)
                                .padding(.top, 2)
                        } else {
                            Text("No data pulled yet.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.label)
                                    .font(.callout).bold()
                                if let snap { compactSummary(snap) }
                            }
                            Spacer()
                            Button {
                                Task { await manager.resyncHistory(id: entry.id) }
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .buttonStyle(.borderless)
                            .help("Re-sync full transaction history for \(entry.label)")
                            .disabled(manager.isRefreshing || manager.isResyncing)
                            Button {
                                Task { await manager.rotateToken(id: entry.id) }
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.borderless)
                            .help("Rotate access token for \(entry.label)")
                            .disabled(manager.isRotating)
                            Button {
                                manager.removeToken(id: entry.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(entry.label)")
                        }
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                }
            }
        }
    }

    private var addTokenForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Label (e.g. Chase Checking)", text: $tokenLabelInput)
                .textFieldStyle(.roundedBorder)
            SecureField("access_token", text: $tokenValueInput)
                .textFieldStyle(.roundedBorder)
            Button("Add Access Token") {
                Task {
                    await apiManager.addAccessToken(label: tokenLabelInput, token: tokenValueInput)
                    tokenLabelInput = ""
                    tokenValueInput = ""
                    // Pull immediately so the new token's data appears.
                    await manager.performPeriodicAPICall()
                    // Auto-start background pulls once the first token exists.
                    manager.resumeBackgroundIfEnabled()
                }
            }
            .disabled(!canAddToken)
        }
    }

    /// One-line status shown in the collapsed token row.
    @ViewBuilder
    private func compactSummary(_ labeled: LabeledSnapshot) -> some View {
        if labeled.errorMessage != nil {
            Text("⚠︎ failed")
                .font(.caption2)
                .foregroundColor(.red)
        } else {
            let s = labeled.data
            let newTxns = s.transactions.added.count
            let hard = s.hardErrors.count
            let unavailable = s.issues.count - hard
            HStack(spacing: 6) {
                Text("\(newTxns) new txn\(newTxns == 1 ? "" : "s")")
                if hard > 0 {
                    Text("· \(hard) error\(hard == 1 ? "" : "s")").foregroundColor(.red)
                }
                if unavailable > 0 {
                    Text("· \(unavailable) n/a")
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func snapshotDetail(_ labeled: LabeledSnapshot) -> some View {
        if let error = labeled.errorMessage {
            Text("⚠︎ \(error)")
                .font(.caption2)
                .foregroundColor(.red)
        } else {
            let s = labeled.data
            VStack(alignment: .leading, spacing: 1) {
                Text("• Txns: \(s.transactions.added.count) new, \(s.transactions.modified.count) modified")
                Text("• Statements: \(s.statements?.accounts.reduce(0) { $0 + $1.statements.count } ?? 0)")
                Text("• Holdings: \(s.holdings?.holdings.count ?? 0)")
                Text("• Investment txns: \(s.investmentTransactions.transactions.count)")
                Text("• Liability accts: \(s.liabilities?.accounts.count ?? 0)")

                // Per-product issues: availability = gray "not available", real = red.
                ForEach(s.issues) { issue in
                    Text("• \(issue.product): \(issue.isAvailabilityIssue ? "not available" : issue.message)")
                        .foregroundColor(issue.isAvailabilityIssue ? .secondary : .red)
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }
}
