SECRET_PATH ?= secret/rubin/usdf-embargo-dmz
ENV = $(notdir ${CURDIR})

get-secrets-from-vault:
	mkdir -p etc/.secrets/
	# internal redis password and Ceph notification secret
	# Postgres database credentials
	# s3 creds for data from the summit (s3df ceph bucket)
	set -e; for i in redis notification postgres-credentials.txt access_key secret_key; do vault kv get --field=$$i ${SECRET_PATH}/${ENV} > etc/.secrets/$$i ; done
	# optional rucio service account ssh key
	for i in register_svc_rsa; do vault kv get --field=$$i ${SECRET_PATH}/${ENV} > etc/.secrets/$$i || echo ignoring missing $$i ; done

clean-secrets:
	rm -rf etc/.secrets/

run-dump:
	kubectl kustomize .

dump: get-secrets-from-vault run-dump clean-secrets

run-apply:
	kubectl apply -k .

apply: get-secrets-from-vault run-apply clean-secrets


