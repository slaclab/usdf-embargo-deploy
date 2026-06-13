#!/bin/sh

COLLECTION="LSSTCam/runs/DRP/20250420_20250521/w_2025_21/DM-51076"
TICKET="DM-51076"

# Ticket number is used in the job name, which must be DNS-compatible,
# so lower-case it.
lowerticket=$(echo $TICKET | tr A-Z a-z)

# Get the initials (in lower case) of each dataset type in the collection.
dsinit=$(butler query-dataset-types embargo --collections "$COLLECTION" |
	 tail -n +3 | cut -c1 | tr A-Z a-z | sort -u)
for i in $dsinit; do
    upper=$(echo $i | tr a-z A-Z)
    glob="[$i$upper]*"

    # Create a job deployment YAML using the dataset initial.
    cat > ${TICKET}-$i.yaml <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: transfer-${lowerticket}-${i}
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
            cp -RL /tmp/secrets-non-raw/* /secrets/
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
        - name: secrets-non-raw
          mountPath: /tmp/secrets-non-raw
          readOnly: true
        - name: secrets
          mountPath: /secrets/
          readOnly: false
      containers:
      - name: transfer-non-raw
        image: ghcr.io/lsst-dm/transfer-non-raw:tickets-DM-51296
        imagePullPolicy: Always
        command:
          - /bin/sh
          - "-c"
          - |
            umask 027
            python transfer_non_raw.py embargo /repo/main --dataqueries "\$DATA_QUERIES" 2>&1 |
            if [ -d "\$LOGDIR" ]; then
              mkdir -p "\$LOGDIR"/$(date +\%Y-\%m)/$(date -I)
              tee "\$LOGDIR/$(date +\%Y-\%m)/$(date -I)/${TICKET}-${i}-$(date -Im)".log
            else
              cat
            fi
        env:
        - name: DATA_QUERIES
          value: |
            - dataset_types: "${glob}"
              collections: "${COLLECTION}"
              embargo_hours: 720
              instrument: "LSSTCam"
              where: ""
              avoid_dstypes_from_collections:
                - "refcats/*"
                - "skymaps"
                - "pretrained_models/*"
                - "LSSTCam/raw/all"
                - "LSSTCam/calib/*"
        - name: TMPDIR
          value: "/tmp"
        - name: LOGNAME
          value: "rubinmgr"
        - name: HOME
          value: "/tmp"
        - name: PGUSER
          value: "rubin"
        - name: PGPASSFILE
          value: "/secrets/postgres-credentials.txt"
        - name: DAF_BUTLER_REPOSITORY_INDEX
          value: "/sdf/group/rubin/shared/data-repos.yaml"
        - name: LSST_RESOURCES_S3_PROFILE_embargo
          value: "https://sdfembs3.sdf.slac.stanford.edu"
        - name: AWS_SHARED_CREDENTIALS_FILE
          value: "/secrets/aws-credentials.ini"
        - name: LOGDIR
          value: "/sdf/data/rubin/user/rubinmgr/transfer_embargo/logs-non-raw/"
        resources:
          limits:
            cpu: "4"
            memory: "2Gi"
          requests:
            cpu: "1"
            memory: "500Mi"
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
      - name: secrets-non-raw
        secret:
          secretName: transfer-secrets-gc7fdd7d6c
          items:
          - key: aws-credentials.ini
            path: aws-credentials.ini
          - key: postgres-credentials.txt
            path: postgres-credentials.txt
          defaultMode: 0400
      - name: sdf-data-rubin
        persistentVolumeClaim:
          claimName: sdf-data-rubin
      - name: sdf-group-rubin
        persistentVolumeClaim:
          claimName: sdf-group-rubin
EOF
     # Now start the job.
     kubectl apply -f ${TICKET}-$i.yaml
done
