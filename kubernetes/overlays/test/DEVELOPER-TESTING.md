# Testing embargo-butler (Kafka notification path)

This guide documents how to validate **Kafka notification → enqueue → Redis → ingest → Butler** for embargo-butler, in both environments:

| Environment | k8s namespace | vcluster | Butler repo |
|-------------|---------------|----------|-------------|
| **dev** | `test` | usdf-embargo-dmz-dev | `/butler` (SQLite on a PVC, created by the ingest initContainer; isolated from prod) |
| **prod** | `summit-new` | usdf-embargo-dmz | `s3://embargo@rubin-summit-users/butler.yaml` (shared production registry) |

> **Notification path changed (DM-54533).** `enqueue` no longer runs an HTTP `/notify`
> webhook. It is now a **Kafka consumer** of the RGW S3 `ObjectCreated` notifications.
> There is no enqueue LoadBalancer/port-forward to reach anymore; to inject a test
> notification you **produce a message onto the Kafka topic** with
> **`scripts/trigger_ingest_dmz_dev_for_kafka.py`** (the older
> `trigger_ingest_dmz_dev.py` posted to the retired webhook and should not be used).

Raw files stay on **embargo S3** (`transfer="direct"`); in dev the PVC holds **registry + sqlite**, not the FITS pixels.

## Prerequisites

- `kubectl` context pointed at the right vcluster, with access to the namespace
  (`test` for dev, `summit-new` for prod).
- **Rubin stack** sourced (for `lsst.resources` and `confluent-kafka`, which ship with
  `lsst-scipipe-13.0.0`). `lsst.daf.butler` is only needed when you pass `--host-butler`.
- **Vault:** `export VAULT_ADDR=https://vault.slac.stanford.edu` and `vault login -method=ldap`
  (the trigger reads the S3 `profile` field from Vault to list S3 and gate records on existence).
- The trigger talks to Redis for `--force` via `kubectl exec redis-0`, so your `kubectl`
  context must reach the target namespace.

## Simulate a notification: `scripts/trigger_ingest_dmz_dev_for_kafka.py`

The script builds the same S3 `ObjectCreated` event JSON that RGW publishes and produces
**one Kafka message per obs_id**. It only emits records for objects that actually exist on
S3 (`ResourcePath(...).exists()`), so non-existent/untaken sequences are skipped.

### Dev (`test` namespace)

Defaults already target dev (`KAFKA_CLUSTER=172.24.10.50:9094`,
`KAFKA_TOPIC=prompt-processing-dev-20260114`,
`VAULT_SECRET_MOUNT_PATH=secret/rubin/usdf-embargo-dmz-dev/test`, namespace `test`):

```bash
export VAULT_ADDR=https://vault.slac.stanford.edu
vault login -method=ldap

python3 scripts/trigger_ingest_dmz_dev_for_kafka.py MC_O_20260324_000404
python3 scripts/trigger_ingest_dmz_dev_for_kafka.py MC_O_20260324_000404_R22_S11   # single detector
```

### Prod (`summit-new` namespace)

Override the Kafka destination, the Vault path, and the namespace used by `--force`:

```bash
export VAULT_ADDR=https://vault.slac.stanford.edu
vault login -method=ldap

KAFKA_CLUSTER=172.24.10.54:9094 \
KAFKA_TOPIC=rubin-summit-notification-8 \
VAULT_SECRET_MOUNT_PATH=secret/rubin/usdf-embargo-dmz/summit-new \
EMBARGO_K8S_NAMESPACE=summit-new \
  python3 scripts/trigger_ingest_dmz_dev_for_kafka.py MC_O_20260603_000258
```

> ⚠️ **`rubin-summit-notification-8` is the shared production topic** — RGW publishes real
> notifications to it and other consumers (e.g. Prompt Processing) read from it. Anything you
> produce is visible to every consumer group. For a smoke test, prefer re-notifying an exposure
> that is **already ingested** (you'll just see `Already ingested`), and/or pass `--host-butler`
> so the script queries the real Butler and only emits records for **not-yet-ingested** detectors.

### Observation ID format (important)

- Use an **observation id**, **not** a filename.
- **Correct:** `MC_O_<day_obs>_<seq>` or `MC_O_<day_obs>_<seq>_R<raft>_S<sensor>`
  (e.g. `MC_O_20260324_000404_R22_S11`).
- **Wrong:** `..._R22_S11.fits` — the `.fits` suffix breaks parsing and produces bad S3 keys
  (you'll get no OID lines and nothing produced).

### What "success" looks like from the trigger

- **Stderr:** `# kafka=<bootstrap>  topic=<topic>  skip_host_butler=True  force=<bool>  namespace=<ns>`
- **Stdout:** one line per **OID** actually sent (object exists on S3).
- **Stderr:** `# produced obs_id=<id> partition=<p> offset=<o>` per exposure
  (or `# FAILED obs_id=<id>: <err>` on a delivery error).

### Re-triggering an already-seen path: `--force`

`enqueue` keeps an `ENQ:<path>` dedupe key for 24h, so re-producing a path enqueued in the last
day is **skipped** (you'll see `Skipping duplicate enqueue …` in enqueue logs). `--force` DELs
those keys in Redis (`kubectl exec redis-0`) just before producing:

```bash
python3 scripts/trigger_ingest_dmz_dev_for_kafka.py --force --namespace summit-new MC_O_20260603_000258
```

> **Known limitation:** for a full-focal-plane LSSTCam exposure (~197 paths) the single
> `kubectl exec … DEL <all keys>` can exceed the API-server/nginx URI limit (**HTTP 414**) and
> the DEL silently fails, so the re-trigger gets deduped and nothing ingests. If you hit that,
> clear the keys **inside the pod** by pattern instead:
>
> ```bash
> kubectl -n summit-new exec redis-0 -- sh -c \
>   'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning --scan --pattern "ENQ:*MC_O_20260603_000258*" \
>      | xargs -r redis-cli -a "$REDIS_PASSWORD" --no-auth-warning DEL'
> ```
>
> then re-run the trigger **without** `--force`. (Note: an already-ingested exposure will still
> only log `Already ingested` — raws are immutable.)

### S3 credentials for local checks

- **`EMBARGO_AWS_CREDENTIALS_FILE`** is only read by the trigger (it copies it to
  `AWS_SHARED_CREDENTIALS_FILE`).
- For ad-hoc `python -c` / `ResourcePath`, set `AWS_SHARED_CREDENTIALS_FILE` and
  `AWS_ENDPOINT_URL` (e.g. `https://sdfembs3.sdf.slac.stanford.edu`) yourself.

Persistent credentials file from Vault (kept after exit):

```bash
python3 scripts/trigger_ingest_dmz_dev_for_kafka.py --aws-credentials-out ~/.aws/embargo-sdf.credentials
export AWS_SHARED_CREDENTIALS_FILE=$HOME/.aws/embargo-sdf.credentials
export AWS_ENDPOINT_URL=https://sdfembs3.sdf.slac.stanford.edu   # if stderr printed it
```

### Listing S3 prefixes with `lsst.resources`

Directory prefixes must end with `/` or `walk()` raises *non-directory URI*.

```python
p = ResourcePath("s3://embargo@rubin-summit/LSSTCam/20260603/")
for c in p.walk():
    ...
```

## Redis (password required)

Redis uses `--requirepass`. Kustomize `secretGenerator` creates a secret named `redis-<hash>`,
not bare `redis`. Use the password already injected in the pod (works in either namespace —
swap `-n test` / `-n summit-new`):

```bash
kubectl -n summit-new exec redis-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" PING'

# Queue for the LSSTCam summit embargo bucket; should drain toward 0 as ingest works:
kubectl -n summit-new exec redis-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning LLEN QUEUE:embargo@rubin-summit'
```

## Enqueue logs (Kafka consumer)

```bash
kubectl -n summit-new logs deploy/embargo-butler-enqueue --since=5m | grep -E "Enqueued|Skipping duplicate"
```

- On startup: `Kafka consumer started: topic=… cluster=… group=…`.
- On accept: `Enqueued embargo@rubin-summit/LSSTCam/.../....fits to embargo@rubin-summit`.
- On a live dedupe key: `Skipping duplicate enqueue …` (use `--force`, or clear the `ENQ:` keys).

## Ingest logs

In prod there are 8 ingest replicas (`app=ingest`); tail them all:

```bash
kubectl -n summit-new logs -l app=ingest --all-containers --prefix --since=5m --max-log-requests=10 \
  | grep -E "Ingesting|Ingested FileDataset|Already ingested|Defined visits"
```

Look for `Ingesting [ResourcePath("s3://...")]`, then `Ingested FileDataset(...)`, and (non-LFA)
`Defined visits for {...}`. `Already ingested` is the expected result when re-notifying an
exposure that is already in the Butler.

## Verify in the Butler

**Dev** (SQLite `/butler`, inside the ingest pod — `loadLSST.bash` is at the stack root):

```bash
kubectl -n test exec deploy/embargo-butler-ingest -c ingest -- bash -lc \
  'source /opt/lsst/software/stack/loadLSST.bash && setup lsst_obs && \
   butler query-datasets --collections LSSTCam/raw/all /butler "*"'
```

**Prod** (shared registry; from a stack-sourced shell on a login node — `embargo_new` is the
usual repo alias for `s3://embargo@rubin-summit-users/butler.yaml`). `query-datasets` requires
`--collections`:

```bash
butler query-datasets embargo_new raw --collections LSSTCam/raw/all \
  --where "instrument='LSSTCam' AND day_obs=20260603 AND exposure.seq_num=258"
```

After a successful raw ingest a RUN `LSSTCam/raw/all` exists; `butler query-collections` lists it.

## End-to-end checklist

1. **Trigger:** OID lines printed + `# produced obs_id=… partition=… offset=…`.
2. **Enqueue:** `Enqueued … to embargo@rubin-summit` (not `Skipping duplicate …`).
3. **Queue:** `LLEN QUEUE:embargo@rubin-summit` drains toward 0.
4. **Ingest:** `Ingested FileDataset` (or `Already ingested` for an existing exposure).
5. **Butler:** `query-datasets --collections LSSTCam/raw/all` returns the rows.

## Related repositories

- **This repo (`usdf-embargo-deploy`):** kustomize overlays (`kubernetes/overlays/test`,
  `kubernetes/overlays/summit-new`), the Kafka trigger
  `scripts/trigger_ingest_dmz_dev_for_kafka.py`, the bucket-notification provisioning under
  `bucket-notifications/`, and this guide.
- **[embargo-butler](https://github.com/lsst-dm/embargo-butler):** service source
  (`src/enqueue.py` — Kafka consumer; `src/ingest.py`; `src/presence.py`).
