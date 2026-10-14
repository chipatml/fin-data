# GCP setup scripts

These scripts prepare a Cloud Storage bucket and service account for FinAgent, and attach an organization `environment` tag to the project. They use the active `gcloud` account. `PROJECT_ID` defaults to `gcloud config get-value project`. The id `wl-screener-20260908-e7bc` below is a documented example only; it is not a fallback inside the scripts.

JSON keys written under this directory are gitignored. Import a key into FinAgent, then delete the file.

The caller needs permission to create buckets, service accounts, and keys, plus org tag admin (`roles/resourcemanager.tagAdmin`) and permission to bind tags on the project (`roles/resourcemanager.tagUser`).

## Tag a project

```bash
./scripts/gcp/add-env-tag.sh
./scripts/gcp/add-env-tag.sh Development
./scripts/gcp/add-env-tag.sh Production wl-screener-20260908-e7bc
```

`ENV_VALUE` is one of `Production`, `Development`, `Test`, or `Staging` (default `Development`). The script reads the project number, finds the organization with `gcloud projects get-ancestors`, creates the tag key `ORG_ID/environment` and the value when they are missing, and binds the value to `//cloudresourcemanager.googleapis.com/projects/PROJECT_NUMBER`. If that value is already bound, it leaves it. If the project has no organization, environment tags cannot be created; the script prints that this warning can be ignored and exits 0.

## Bucket

```bash
./scripts/gcp/create-bucket.sh my-finagent-bucket
./scripts/gcp/create-bucket.sh my-finagent-bucket us-central1 wl-screener-20260908-e7bc --versioning
```

Location defaults to `us-central1`. Create is skipped when the bucket exists. Uniform bucket-level access stays on, and public access prevention stays enforced. `--versioning` enables object versioning; omitting it does not turn versioning off.

## Service account

```bash
./scripts/gcp/create-service-account.sh finagent-gcs
./scripts/gcp/create-service-account.sh finagent-gcs wl-screener-20260908-e7bc \
  --display-name "FinAgent Cloud Storage" \
  --key ./scripts/gcp/finagent-gcs-key.json
```

Create is skipped when `finagent-gcs@PROJECT_ID.iam.gserviceaccount.com` already exists. `--key` writes a new JSON key (mode `600`) and prints a reminder to import it into the FinAgent Cloud Storage panel, then delete it:

```bash
rm -f ./scripts/gcp/finagent-gcs-key.json
```

Each `--key` run creates another key. The script will not overwrite an existing outfile.

## Bucket IAM

```bash
./scripts/gcp/grant-bucket-access.sh my-finagent-bucket finagent-gcs --readwrite
./scripts/gcp/grant-bucket-access.sh my-finagent-bucket finagent-gcs@wl-screener-20260908-e7bc.iam.gserviceaccount.com --readonly
./scripts/gcp/grant-bucket-access.sh my-finagent-bucket finagent-gcs --readwrite --revoke
```

`--readwrite` binds `roles/storage.objectAdmin` (FinAgent uploads day files). `--readonly` binds `roles/storage.objectViewer`. A short account name is expanded with the project from `--project` or gcloud config. Grant and revoke both no-op when the binding is already in the requested state.

## All of the above

```bash
./scripts/gcp/setup-all.sh my-finagent-bucket us-central1 wl-screener-20260908-e7bc \
  --sa-name finagent-gcs \
  --env Development \
  --versioning \
  --key /tmp/finagent-gcs-key.json
```

This creates the bucket, creates the service account, grants read-write access (or `--readonly`), and applies the environment tag. Import `/tmp/finagent-gcs-key.json` into FinAgent, then `rm -f` that file.
