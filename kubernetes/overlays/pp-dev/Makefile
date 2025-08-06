SECRET_PATH ?= secret/rubin/usdf-prompt-processing-dev/autoingest
ENV = $(notdir ${CURDIR})

get-secrets-from-vault:
	mkdir -p etc/.secrets/
	# internal Ceph notification secret
	set -e; for i in redis notification profile; do vault kv get --field=$$i ${SECRET_PATH}/${ENV} > etc/.secrets/$$i ; done
	# butler dbauth.yaml file with creds
	set -e; for i in db-auth.yaml; do vault kv get --field=$$i ${SECRET_PATH}/${ENV} > etc/.secrets/$$i ; done

clean-secrets:
	rm -rf etc/.secrets/

run-dump:
	kubectl kustomize .

dump: get-secrets-from-vault run-dump clean-secrets

run-apply:
	kubectl apply -k .

apply: get-secrets-from-vault run-apply clean-secrets
