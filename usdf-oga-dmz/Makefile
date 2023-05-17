SECRET_PATH ?= secret/rubin/usdf-embargo-dmz-dev/

get-secrets-from-vault:
	mkdir -p etc/.secrets/
	# internal redis password
	set -e; for i in password; do vault kv get --field=$$i secret/rubin/usdf-embargo-dmz-dev/redis > etc/.secrets/$$i ; done
	# butler dbauth.yaml file with creds
	set -e; for i in db-auth.yaml; do vault kv get --field=$$i secret/rubin/usdf-butler/client-config > etc/.secrets/$$i ; done
	# s3 creds for data from the summit (s3df ceph bucket)
	set -e; for i in access_key secret_key; do vault kv get --field=$$i secret/rubin/embargo/read/rubin-summit-users > etc/.secrets/$$i ; done
	# ceph notification secret
	set -e; for i in secret; do vault kv get --field=$$i secret/rubin/usdf-embargo-dmz-dev/notification > etc/.secrets/$$i; done

clean-secrets:
	rm -rf etc/.secrets/

run-dump:
	kubectl kustomize .

dump: get-secrets-from-vault run-dump clean-secrets

run-apply:
	kubectl apply -k .

apply: get-secrets-from-vault run-apply clean-secrets


