# FinAgentMenuBar

macOS menu-bar app. Day files live under `~/Library/Application Support/FinAgentMenuBar/Data`.

## Rebuild and relaunch

From any directory:

```bash
FinAgentMenuBar/scripts/rebuild.sh
```

The script fast-forwards the current branch, quits FinAgentMenuBar if it is open, builds the Debug app, and opens it. Derived data goes in `build/` at the repo root, which is gitignored.

```bash
FinAgentMenuBar/scripts/rebuild.sh --no-pull    # build this checkout without pulling
FinAgentMenuBar/scripts/rebuild.sh --release    # Release configuration
```

`DEVELOPMENT_TEAM` defaults to `YM26CY2452`. Set that environment variable to use another Apple team. The script exits with an error if `xcodebuild` is not installed.

## Cloud Storage

Cloud Storage is the only remote mirror. Day files upload to `gs://<bucket>/<prefix>/<YYYY-MM-DD>/<Label>.json`. Google Drive sign-in, the Drive folder mirror, and the “Copy Drive files into the bucket” action are gone. The first launch after this upgrade deletes leftover Drive Keychain items (OAuth client id, client secret, refresh token) and Drive UserDefaults keys. That cleanup is best-effort and does not ask for Touch ID.

Create the bucket and service account with `scripts/gcp/` at the repo root. Paste the JSON key into the Cloud Storage panel; the app stores it in the Keychain. To copy an existing Data folder from Terminal:

```bash
gcloud storage rsync --recursive \
  "$HOME/Library/Application Support/FinAgentMenuBar/Data" \
  "gs://BUCKET/FinAgentMenuBar"
```
