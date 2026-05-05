#!/usr/bin/env python3
"""Simulate Ceph S3 webhook POSTs to embargo-butler enqueue (dmz-dev ``test`` namespace).

Deploy manifests and testing guide: ``kubernetes/overlays/test/`` in **usdf-embargo-deploy**
(``DEVELOPER-TESTING.md``).

The in-cluster Butler is created under ``/butler`` (SQLite on PVC). Your laptop
``Butler("embargo")`` is a different registry — by default this script **does not**
query it; only S3 ``path.exists()`` gates records. Use ``--host-butler`` to use
the host embargo Butler for skip logic.

Usage::
    export VAULT_ADDR=https://vault.slac.stanford.edu
    vault login -method=ldap
    kubectl port-forward -n test svc/embargo-butler-enqueue 8080:8080   # if LB pending
    python scripts/trigger_ingest_dmz_dev.py MC_O_20260125_001234

    # Persistent S3 credentials (not deleted on exit); then reuse in your shell:
    python scripts/trigger_ingest_dmz_dev.py --aws-credentials-out ~/.aws/embargo-sdf.credentials
    export EMBARGO_AWS_CREDENTIALS_FILE=$HOME/.aws/embargo-sdf.credentials
    export AWS_ENDPOINT_URL=https://...   # if the script printed # AWS_ENDPOINT_URL=...

Environment variables
---------------------
EMBARGO_K8S_NAMESPACE
    Kubernetes namespace (default: ``test``).
EMBARGO_NOTIFY_URL
    Full base URL for POST (default: LB IP via kubectl, else ``http://127.0.0.1:8080``).
VAULT_NOTIFICATION_MOUNT_PATH
    Path for ``vault kv get -field=notification`` (default: ``secret/rubin/usdf-embargo-dmz-dev/test``).
VAULT_SECRET_MOUNT_PATH
    Single Vault path for both ``notification`` and ``profile`` fields (default: same as notification path).
EMBARGO_AWS_CREDENTIALS_FILE
    If set, **this script** copies it to ``AWS_SHARED_CREDENTIALS_FILE`` before S3 calls (skip Vault profile fetch).
    For ad-hoc ``python -c`` / ``ResourcePath``, set ``AWS_SHARED_CREDENTIALS_FILE`` yourself — boto does not read ``EMBARGO_*``.
    Create a persistent file with ``--aws-credentials-out PATH`` (or ``vault kv get -field=profile ...`` and convert URL form to INI; see script help).
SKIP_BUTLER_CHECK
    If ``0``/``false``, same as ``--host-butler`` when set explicitly (see below).
"""

import argparse
import atexit
import os
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlparse

import requests
from lsst.daf.butler import Butler, EmptyQueryResultError
from lsst.resources import ResourcePath

INSTRUMENTS = dict(AT="LATISS", CC="LSSTComCam", TS="TS8", MC="LSSTCam")
BUCKETS = dict(
    AT="embargo@rubin-summit",
    CC="embargo@rubin-summit",
    TS="rubin-sts",
    MC="embargo@rubin-summit",
)
RAFT_LIST = dict(
    AT=["00"],
    CC=["22"],
    TS=["22"],
    MC=[
        "01",
        "02",
        "03",
        "10",
        "11",
        "12",
        "13",
        "14",
        "20",
        "21",
        "22",
        "23",
        "24",
        "30",
        "31",
        "32",
        "33",
        "34",
        "41",
        "42",
        "43",
    ],
)
SENSOR_LIST = dict(
    AT=["00"],
    CC=["00", "01", "02", "10", "11", "12", "20", "21", "22"],
    TS=["00", "01", "02", "10", "11", "12", "20", "21", "22"],
    MC=["00", "01", "02", "10", "11", "12", "20", "21", "22"],
)
CORNER_LIST = ["00", "04", "40", "44"]
CORNER_SENSORS = ["W0", "W1", "G0_guider", "G1_guider"]

_DEFAULT_VAULT_SECRET = "secret/rubin/usdf-embargo-dmz-dev/test"
_temp_aws_files = []
_atexit_cleanup_registered = False


def _truthy(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "y")


def _falsy(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in ("0", "false", "no", "n")


def _vault_secret_path() -> str:
    return os.environ.get(
        "VAULT_SECRET_MOUNT_PATH",
        os.environ.get("VAULT_NOTIFICATION_MOUNT_PATH", _DEFAULT_VAULT_SECRET),
    )


def _vault_kv_field(path: str, field: str) -> str:
    cmd = ["vault", "kv", "get", "-field=" + field, path]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        raise RuntimeError("vault failed (%s): %s" % (p.returncode, " ".join(cmd)))
    return p.stdout


def _vault_notification_opaque() -> str:
    return _vault_kv_field(_vault_secret_path(), "notification").strip()


def _cleanup_temp_aws_files() -> None:
    global _temp_aws_files
    for p in list(_temp_aws_files):
        if p and os.path.isfile(p):
            try:
                os.unlink(p)
            except OSError:
                pass
    _temp_aws_files.clear()


def _vault_profile_to_credentials_ini(body: str):
    """Return (credentials_file_contents, endpoint_url_or_none).

    Vault sometimes stores a URL like ``https://ACCESS:SECRET@host`` instead of
    AWS ``[embargo]`` INI; botocore cannot parse the former directly.
    """
    raw = body.strip()
    if not raw:
        return raw, None
    # Standard INI / LSST-style multi-line profile
    if raw.lstrip().startswith("["):
        return raw, None
    u = urlparse(raw)
    if u.scheme in ("http", "https") and u.username and u.password:
        access_key = unquote(u.username)
        secret_key = unquote(u.password)
        host = u.hostname
        if not host:
            return raw, None
        port = u.port
        if port:
            endpoint = "%s://%s:%s" % (u.scheme, host, port)
        else:
            endpoint = "%s://%s" % (u.scheme, host)
        creds = (
            "[embargo]\n"
            "aws_access_key_id = %s\n"
            "aws_secret_access_key = %s\n" % (access_key, secret_key)
        )
        return creds, endpoint
    return raw, None


def _ensure_embargo_s3_credentials(credentials_out: str | None = None) -> None:
    """ResourcePath s3://embargo@... uses boto profile 'embargo'; materialize from Vault if needed."""
    global _temp_aws_files, _atexit_cleanup_registered
    explicit = os.environ.get("EMBARGO_AWS_CREDENTIALS_FILE", "").strip()
    if explicit:
        os.environ["AWS_SHARED_CREDENTIALS_FILE"] = explicit
        return
    if os.environ.get("AWS_SHARED_CREDENTIALS_FILE", "").strip():
        return
    body = _vault_kv_field(_vault_secret_path(), "profile")
    cred_contents, endpoint_url = _vault_profile_to_credentials_ini(body)
    if credentials_out:
        path = os.path.abspath(os.path.expanduser(credentials_out))
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, mode=0o700, exist_ok=True)
        with open(path, "w") as fh:
            fh.write(cred_contents)
        os.chmod(path, 0o600)
        os.environ["AWS_SHARED_CREDENTIALS_FILE"] = path
        if endpoint_url and not os.environ.get("AWS_ENDPOINT_URL", "").strip():
            os.environ["AWS_ENDPOINT_URL"] = endpoint_url
            print("# AWS_ENDPOINT_URL=%s (from Vault profile URL)" % endpoint_url, file=sys.stderr)
        print("# wrote persistent AWS_SHARED_CREDENTIALS_FILE=%s" % path, file=sys.stderr)
        return
    fd, path = tempfile.mkstemp(prefix="embargo-trigger-", suffix=".credentials", text=True)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(cred_contents)
    except Exception:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    _temp_aws_files.append(path)
    os.environ["AWS_SHARED_CREDENTIALS_FILE"] = path
    if endpoint_url and not os.environ.get("AWS_ENDPOINT_URL", "").strip():
        # Botocore/boto3 1.34+ (Rubin stacks): route S3 API to Ceph/RGW
        os.environ["AWS_ENDPOINT_URL"] = endpoint_url
        print("# AWS_ENDPOINT_URL=%s (from Vault profile URL)" % endpoint_url, file=sys.stderr)
    if not _atexit_cleanup_registered:
        atexit.register(_cleanup_temp_aws_files)
        _atexit_cleanup_registered = True
    print("# AWS_SHARED_CREDENTIALS_FILE=%s (from Vault profile field; deleted on exit)" % path, file=sys.stderr)


def _notify_base_url(namespace: str) -> str:
    explicit = os.environ.get("EMBARGO_NOTIFY_URL", "").strip()
    if explicit:
        return explicit.rstrip("/")
    p = subprocess.run(
        [
            "kubectl",
            "get",
            "svc",
            "embargo-butler-enqueue",
            "-n",
            namespace,
            "-o",
            "jsonpath={.status.loadBalancer.ingress[0].ip}",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    ip = (p.stdout or "").strip()
    if ip:
        return f"http://{ip}:8080"
    host = os.environ.get("EMBARGO_ENQUEUE_HOST", "127.0.0.1")
    port = os.environ.get("EMBARGO_ENQUEUE_PORT", "8080")
    return f"http://{host}:{port}"


class Records:
    def __init__(self, bucket: str, profile: str = "", opaque: str = ""):
        self._profile = profile
        self._bucket = bucket
        self._records: list[dict] = []
        self._opaque = opaque

    def records(self) -> list[dict]:
        return self._records

    def append(self, oid: str, instr_code: str) -> None:
        record = {
            "s3": {
                "bucket": {"name": self._bucket},
                "object": {"key": oid},
            },
            "opaqueData": self._opaque,
        }
        path = ResourcePath(f"s3://{self._profile}{self._bucket}/{oid}")
        if path.exists():
            self._records.append(record)
            print(oid)


def _resolve_skip_butler(args: argparse.Namespace) -> bool:
    """Default: skip (dev SQLite Butler is not host Butler)."""
    if args.host_butler:
        return False
    if "SKIP_BUTLER_CHECK" in os.environ:
        if _falsy("SKIP_BUTLER_CHECK"):
            return False
        if _truthy("SKIP_BUTLER_CHECK"):
            return True
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "obs_ids",
        nargs="*",
        help="Observation ids, e.g. MC_O_20260125_001234 (omit when using only --aws-credentials-out)",
    )
    parser.add_argument(
        "--host-butler",
        action="store_true",
        help="Query Butler('embargo') on this machine for already-ingested detectors",
    )
    parser.add_argument(
        "--aws-credentials-out",
        metavar="PATH",
        help=(
            "Write Vault 'profile' field as boto [embargo] INI to PATH (0600); file is kept after exit. "
            "Use alone with no obs_ids to refresh credentials; then export "
            "EMBARGO_AWS_CREDENTIALS_FILE=PATH (and AWS_ENDPOINT_URL if stderr prints it)."
        ),
    )
    args = parser.parse_args()

    if not args.obs_ids:
        if args.aws_credentials_out:
            _ensure_embargo_s3_credentials(credentials_out=args.aws_credentials_out)
            sys.exit(0)
        parser.error(
            "at least one obs_id is required (unless using only --aws-credentials-out PATH to write credentials)"
        )

    _ensure_embargo_s3_credentials(credentials_out=args.aws_credentials_out)

    namespace = os.environ.get("EMBARGO_K8S_NAMESPACE", "test")
    notify_base = _notify_base_url(namespace)
    opaque = _vault_notification_opaque()
    skip_butler = _resolve_skip_butler(args)

    print(
        f"# notify={notify_base}/notify  namespace={namespace}  skip_host_butler={skip_butler}",
        file=sys.stderr,
    )

    for obs_id in args.obs_ids:
        instr_code, controller, obs_day, seq_num = obs_id.split("_", maxsplit=3)
        instrument = INSTRUMENTS[instr_code]
        bucket = BUCKETS[instr_code]
        if "@" in bucket:
            profile, bucket = bucket.split("@")
            profile += "@"
        else:
            profile = ""

        records = Records(bucket, profile, opaque=opaque)

        if skip_butler:
            ingested: set[str] = set()
        else:
            butler = Butler("embargo", instrument=instrument, collections=f"{instrument}/raw/all")
            detectors = {d.id: d.full_name for d in butler.query_dimension_records("detector")}
            try:
                refs = butler.query_datasets(
                    "raw", where=f"day_obs={obs_day} and exposure.seq_num={seq_num}"
                )
                ingested = {detectors[r.dataId["detector"]] for r in refs}
            except EmptyQueryResultError:
                ingested = set()
            if instrument == "LSSTCam":
                try:
                    refs = butler.query_datasets(
                        "guider_raw",
                        where=f"day_obs={obs_day} and exposure.seq_num={seq_num}",
                        collections=f"{instrument}/raw/guider",
                    )
                    for r in refs:
                        ingested.add(detectors[r.dataId["detector"]] + "_guider")
                except EmptyQueryResultError:
                    pass

        if "_" in seq_num:
            seq_num, raft, sensor = seq_num.split("_")
            obs_id = f"{instr_code}_{controller}_{obs_day}_{seq_num}"
            oid = f"{instrument}/{obs_day}/{obs_id}/{obs_id}_R{raft}_S{sensor}.fits"
            if f"R{raft}_S{sensor}" not in ingested:
                records.append(oid, instr_code)
        else:
            for raft in RAFT_LIST[instr_code]:
                for sensor in SENSOR_LIST[instr_code]:
                    oid = f"{instrument}/{obs_day}/{obs_id}/{obs_id}_R{raft}_S{sensor}.fits"
                    if f"R{raft}_S{sensor}" not in ingested:
                        records.append(oid, instr_code)
            if instrument == "LSSTCam":
                for raft in CORNER_LIST:
                    for sensor in CORNER_SENSORS:
                        oid = f"{instrument}/{obs_day}/{obs_id}/{obs_id}_R{raft}_S{sensor}.fits"
                        if f"R{raft}_S{sensor}" not in ingested:
                            records.append(oid, instr_code)

        payload = {"Records": records.records()}
        url = f"{notify_base}/notify"
        r = requests.post(url, json=payload, timeout=60)
        print(r.status_code, r)
        if not r.ok:
            sys.exit(1)


if __name__ == "__main__":
    main()
