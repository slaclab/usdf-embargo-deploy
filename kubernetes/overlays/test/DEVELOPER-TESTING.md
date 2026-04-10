# Testing embargo-butler on usdf-embargo-dmz-dev (`test` namespace)

This guide documents how to validate **notify → Redis → ingest → Butler** for the **`kubernetes/overlays/test`** kustomize overlay (Kubernetes namespace **`test`** on **usdf-embargo-dmz-dev**). It reflects behavior verified on-cluster.

**Manifests** for this environment live in **this directory**. The S3 notification simulator is **`scripts/trigger_ingest_dmz_dev.py`** (same directory layout as **[embargo-butler](https://github.com/lsst-dm/embargo-butler)** for convenience). Service source remains in **embargo-butler**.

## Dev vs production Butler

| Environment | Typical `BUTLER_REPO` | Notes |
|-------------|----------------------|--------|
| **usdf-embargo-dmz** (prod-style) | `s3://embargo@rubin-summit-users/butler.yaml` | Shared production registry. |
| **usdf-embargo-dmz-dev** (`test`) | `/butler` | **SQLite on a PVC** (`butler-data-pvc`). Created by the ingest **initContainer** (`butler create`, `register-instrument`, etc.). Isolated from prod. |

Ingest in this overlay reads **`BUTLER_REPO`** from `ingest-deploy.yaml` (path `/butler`). Raw files stay on **embargo S3** (`transfer="direct"`); the PVC holds **registry + sqlite**, not the FITS pixels.

## Prerequisites

- `kubectl` context pointed at **usdf-embargo-dmz-dev**; access to namespace **`test`**.
- **Vault:** `VAULT_ADDR`, `vault login`. With `make apply` from **`kubernetes/overlays/test`**, secrets are read from **`secret/rubin/usdf-embargo-dmz-dev/test`** (`ENV` is the directory name `test`). Required fields: **`notification`**, **`profile`**, **`redis`**, **`db-auth.yaml`** (may be empty for SQLite-only ingest).
- **Deploy:** from **`kubernetes/overlays/test`**, run **`make apply`** (creates `etc/.secrets/`, applies kustomize, removes local secret files). Or populate `etc/.secrets/` yourself and run **`kubectl apply -k .`**.
- Reach enqueue **LoadBalancer** or port-forward: service **`embargo-butler-enqueue`**, port **8080** (maps to container port 8000).

## Simulate S3 notifications: `scripts/trigger_ingest_dmz_dev.py`

Run from **`kubernetes/overlays/test`** (this directory) on a host with Rubin stack + Vault + `kubectl` as needed:

```bash
cd kubernetes/overlays/test   # or path to this overlay in your clone
export VAULT_ADDR=https://vault.slac.stanford.edu
vault login -method=ldap
# Optional if no LoadBalancer IP:
# kubectl port-forward -n test svc/embargo-butler-enqueue 8080:8080

python3 scripts/trigger_ingest_dmz_dev.py MC_O_20260324_000404
python3 scripts/trigger_ingest_dmz_dev.py MC_O_20260324_000404_R22_S11   # single detector
```

### Observation ID format (important)

- Use an **observation id**, **not** a filename.
- **Correct:** `MC_O_<day_obs>_<seq>` or `MC_O_<day_obs>_<seq>_R<raft>_S<sensor>` (e.g. `MC_O_20260324_000404_R22_S11`).
- **Wrong:** `..._R22_S11.fits` — the `.fits` suffix breaks parsing and produces bad S3 keys; you may get **HTTP 200** with **no OID lines** and nothing enqueued.

### What “success” looks like from the trigger

- **Stderr:** `# notify=http://<enqueue>:8080/notify ...`
- **Stdout:** one line per **OID** actually sent (object must exist on S3 per `ResourcePath(...).exists()`).
- **HTTP:** `200` — still check for **printed OIDs**; empty `Records` can still return 200.

### S3 credentials for local checks

- **`EMBARGO_AWS_CREDENTIALS_FILE`** is only read by **`trigger_ingest_dmz_dev.py`** (the script copies it to `AWS_SHARED_CREDENTIALS_FILE`).
- For ad-hoc **`python -c`** / **`ResourcePath`**, set **`AWS_SHARED_CREDENTIALS_FILE`** and **`AWS_ENDPOINT_URL`** (e.g. `https://sdfembs3.sdf.slac.stanford.edu` when using the SDF embargo endpoint from Vault).

Persistent credentials file from Vault (does not delete on exit):

```bash
python3 scripts/trigger_ingest_dmz_dev.py --aws-credentials-out ~/.aws/embargo-sdf.credentials  # from this overlay directory
export AWS_SHARED_CREDENTIALS_FILE=$HOME/.aws/embargo-sdf.credentials
export AWS_ENDPOINT_URL=https://sdfembs3.sdf.slac.stanford.edu   # if stderr printed it
```

### Listing S3 prefixes with `lsst.resources`

Directory prefixes must end with **`/`** or `walk()` raises *non-directory URI*.

```python
p = ResourcePath("s3://embargo@rubin-summit/LSSTCam/20260324/")
for c in p.walk():
    ...
```

## Redis (password required)

Redis uses **`--requirepass`**. Kustomize **`secretGenerator`** creates a secret named **`redis-<hash>`**, not bare `redis`.

```bash
kubectl get secrets -n test | grep redis
REDIS_PASS=$(kubectl get secret -n test redis-<suffix> -o jsonpath='{.data.redis-password}' | base64 -d)
kubectl exec -n test redis-0 -- redis-cli -a "$REDIS_PASS" PING
```

Queue used for LSSTCam summit embargo bucket: **`QUEUE:embargo@rubin-summit`**.

Using the password already injected in the Redis pod:

```bash
kubectl exec -n test redis-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" PING'
```

## Enqueue logs

On successful accept you should see a line like:

`Enqueued embargo@rubin-summit/LSSTCam/.../....fits to embargo@rubin-summit`

If **`opaqueData`** does not match **`NOTIFICATION_SECRET`**, records are skipped (possible **200** with no enqueue lines).

## Ingest logs

Look for **`Ingesting [ResourcePath("s3://...")]`**, then **`Ingested FileDataset(...)`**, and (for non-LFA) **`Defined visits for {...}`** after `on_exposure_record`.

## Butler inside the ingest pod

The container **`WORKDIR`** is the stack root; **`loadLSST.bash`** is **not** under `$HOME`. Use:

```bash
source /opt/lsst/software/stack/loadLSST.bash && setup lsst_obs
```

### Collections and queries

After a successful raw ingest, a **RUN** **`LSSTCam/raw/all`** appears. **`butler query-datasets`** must include **`--collections`** (mandatory in newer middleware).

```bash
kubectl exec -n test deploy/embargo-butler-ingest -c ingest -- bash -lc \
  'source /opt/lsst/software/stack/loadLSST.bash && setup lsst_obs && \
   butler query-collections /butler'

kubectl exec -n test deploy/embargo-butler-ingest -c ingest -- bash -lc \
  'source /opt/lsst/software/stack/loadLSST.bash && setup lsst_obs && \
   butler query-datasets --collections LSSTCam/raw/all /butler "*"'
```

`butler query-dataset-types /butler` lists registered types. The init container registers **`guider_raw`**; **`raw`** for science data is registered when **`RawIngestTask`** ingests (dimensions match the instrument/stack, e.g. `band`, `instrument`, `day_obs`, `detector`, `group`, `physical_filter`, `exposure` for LSSTCam in current stacks).

## End-to-end checklist

1. **Trigger:** OID lines printed + **200**.
2. **Enqueue:** log line **`Enqueued ... to embargo@rubin-summit`**.
3. **Ingest:** **`Ingested FileDataset`** with **`raw`** and **`run='LSSTCam/raw/all'`**.
4. **Butler:** **`butler query-collections /butler`** shows **`LSSTCam/raw/all`**; **`query-datasets`** with **`--collections LSSTCam/raw/all`** lists rows.

## Related repositories

- **This repo (`usdf-embargo-deploy`):** `kubernetes/overlays/test/` manifests, **`scripts/trigger_ingest_dmz_dev.py`**, and this guide.
- **[embargo-butler](https://github.com/lsst-dm/embargo-butler):** service source (`src/enqueue.py`, `src/ingest.py`, …). A copy of the trigger script may also live under **`scripts/`** there for development; prefer the path above for dmz-dev testing alongside manifests.
