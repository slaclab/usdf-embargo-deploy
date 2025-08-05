#!/bin/bash

# This script runs unembargo for a selected list of datasets.

if [[ $# -lt 1 || ! -r "$1" ]]; then
  echo "Missing or unreadable dataset list"
  exit 1
fi
if [ $(kubectl config current-context) != "usdf-embargo-dmz" ]; then
  echo "Wrong vcluster context for kubectl"
  exit 2
fi
if ! kubectl get ns | grep transfer > /dev/null; then
  echo "No kubectl access to vcluster"
  exit 2
fi
label=$(basename $1 .datasets)
njobs=${2:-1}

split -n r/$njobs --numeric-suffixes=1 $1 ${label}.part

for i in $(seq -w 01 $njobs); do
  infile=$(realpath "${label}.part$i")
  # Generate Kubernetes Job to process the list.
  # TODO: Fix hard-coded secret version by using kustomize
  # TODO: Merge and version the container.
  cat > ${label}-${i}-from-list.yaml <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: from-list-${label}-${i}-$(date +%s)
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
      - name: transfer-from-list
        image: ghcr.io/lsst-dm/transfer-from-list:tickets-DM-51891
        imagePullPolicy: Always
        env:
        - name: INFILE
          value: "$infile"
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
  kubectl apply -f ${label}-${i}-from-list.yaml
done
