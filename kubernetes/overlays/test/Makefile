# Vault KV v2: secret rubin/usdf-embargo-dmz-dev/test must contain fields:
#   redis, notification, profile, db-auth.yaml (db-auth may be empty for SQLite-only ingest)
SECRET_PATH ?= secret/rubin/usdf-embargo-dmz-dev
ENV = $(notdir ${CURDIR})

get-secrets-from-vault:
	mkdir -p etc/.secrets/
	set -e; for i in redis notification profile; do vault kv get --field=$$i ${SECRET_PATH}/${ENV} > etc/.secrets/$$i ; done
	set -e; for i in db-auth.yaml; do vault kv get --field=$$i ${SECRET_PATH}/${ENV} > etc/.secrets/$$i ; done

clean-secrets:
	rm -rf etc/.secrets/

run-dump:
	kubectl kustomize .

dump: get-secrets-from-vault run-dump clean-secrets

run-apply:
	kubectl apply -k .

apply: get-secrets-from-vault run-apply clean-secrets
