#!/bin/bash

# This script runs unembargo for a selected day_obs, starting at 12:00 UTC
# the next day and going backwards 25 hours (in case of daytime calibrations
# overlapping the day change).

if [[ $# -lt 1 ]]; then
  echo "Missing date (YYYY-MM-DD) parameter"
  exit 1
fi
if ! kubectl get ns | grep transfer > /dev/null; then
  echo "No kubectl access or wrong vcluster"
  exit 2
fi
DAY_OBS=$1
if ! echo $DAY_OBS | grep -e '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$'; then
  echo "Date must be YYYY-MM-DD"
  exit 1
fi
if ! NEXT_DAY=$(date -I -d "$DAY_OBS 1 day"); then
  echo "Cannot compute next day"
  exit 1
fi
if [[ "$NEXT_DAY" > $(date -I) ]]; then
  echo "$NEXT_DAY is in the future"
  exit 1
fi

# Generate a Kubernetes Job to process the day.
# TODO: Fix hard-coded config and secret version by using kustomize
# TODO: Merge and version the container.
cat > ${DAY_OBS}-catchup.yaml <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: catchup-raw-${DAY_OBS}-$(date +%s)
  namespace: transfer
spec:
  template:
    spec:
      restartPolicy: Never
      initContainers:
      - name: fix-secret-permissions
        image: busybox
        imagePullPolicy: IfNotPresent
        command: ["/bin/sh"]
        args:
          - -c
          - |
            cp -RL /tmp/secrets-raw/* /secrets/
            chown 18296:4085 /secrets/*
            chmod 0400 /secrets/*
        resources:
          limits:
            cpu: "1"
            memory: "100Mi"
          requests:
            cpu: "100m"
            memory: "10Mi"
        volumeMounts:
        - name: secrets-raw
          mountPath: /tmp/secrets-raw
          readOnly: true
        - name: secrets
          mountPath: /secrets/
          readOnly: false
      containers:
      - name: transfer-raws-catchup
        image: ghcr.io/lsst-dm/transfer-raw:tickets-DM-51296
        imagePullPolicy: Always
        env:
        - name: WINDOW
          value: 25hr
        - name: NOW
          value: "--now ${NEXT_DAY}T12:00"
        - name: TRANSFER_CONFIG
          value: "/config/config_raw.yaml"
        - name: RUCIO_CONFIG
          value: "/config/rucio.cfg"
        - name: PGUSER
          value: "transfer_embargo"
        - name: PGPASSFILE
          value: "/secrets/postgres-credentials.txt"
        - name: DAF_BUTLER_REPOSITORY_INDEX
          value: "/sdf/group/rubin/shared/data-repos.yaml"
        - name: LSST_RESOURCES_S3_PROFILE_embargo
          value: "https://sdfembs3.sdf.slac.stanford.edu"
        - name: AWS_SHARED_CREDENTIALS_FILE
          value: "/secrets/aws-credentials.ini"
        - name: LOGDIR
          value: "/sdf/data/rubin/user/rubinmgr/transfer_embargo/logs-jobs/"
        resources:
          limits:
            cpu: "4"
            memory: "1Gi"
          requests:
            cpu: "500m"
            memory: "100Mi"
        securityContext:
          runAsUser: 18296
          runAsGroup: 4085
        volumeMounts:
        - name: secrets
          mountPath: /secrets/
          readOnly: true
        - name: temp
          mountPath: /tmp/
        - name: config
          mountPath: /config/
          readOnly: true
        - name: sdf-data-rubin
          mountPath: /sdf/data/rubin/
        - name: sdf-group-rubin
          mountPath: /sdf/group/rubin/
      volumes:
      - name: secrets
        emptyDir:
          sizeLimit: 1Mi
      - name: temp
        emptyDir:
          sizeLimit: 16Gi
      - name: secrets-raw
        secret:
          secretName: transfer-secrets-94ddchd28g
          items:
          - key: aws-credentials.ini
            path: aws-credentials.ini
          - key: postgres-credentials.txt
            path: postgres-credentials.txt
          - key: rucio_key
            path: rucio_key
          defaultMode: 0400
      - name: config
        configMap:
          name: transfer-raw-config-b5458d59m7
      - name: sdf-data-rubin
        persistentVolumeClaim:
          claimName: sdf-data-rubin
      - name: sdf-group-rubin
        persistentVolumeClaim:
          claimName: sdf-group-rubin
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sdf-data-rubin
spec:
  storageClassName: sdf-data-rubin
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sdf-group-rubin
spec:
  storageClassName: sdf-group-rubin
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
EOF
# Apply the YAML to create the job
kubectl apply -f ${DAY_OBS}-catchup.yaml
