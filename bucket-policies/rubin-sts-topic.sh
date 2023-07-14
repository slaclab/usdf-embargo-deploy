alias sns='singularity exec /sdf/sw/s3/aws-cli_latest.sif aws --endpoint-url https://s3dfrgw.slac.stanford.edu sns --region=""'
sns delete-topic --topic-arn=arn:aws:sns:default::rubin-sts
sns create-topic --name=rubin-sts --attributes='{"push-endpoint": "http://172.24.5.180:8080/notify", "OpaqueData": "GET FROM VAULT", "persistent": "true" }'
