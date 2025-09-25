#!/bin/bash
set -e
shopt -s expand_aliases

#Set S3 profile
profile=ppdev

# Alias s3api and sns commands
alias sns='apptainer exec /sdf/sw/s3/aws-cli_latest.sif aws --endpoint-url https://s3dfrgw.slac.stanford.edu sns --region="" --profile=$profile'
alias s3api="apptainer exec /sdf/sw/s3/aws-cli_latest.sif aws --endpoint-url https://s3dfrgw.slac.stanford.edu s3api --profile=$profile"

# Clear the bucket notification configuration
s3api --profile=$profile put-bucket-notification-configuration --bucket=rubin-pp-dev --notification-configuration=file://blank-topic-config.json

# Delete the current topics and create a new ones
sns delete-topic --topic-arn=arn:aws:sns:default::pp-dev-microservice-202509
sns delete-topic --topic-arn=arn:aws:sns:default::prompt-processing-dev
sns create-topic --name=pp-dev-microservice-202509 --attributes='{"push-endpoint": "http://172.24.10.33:8080/notify", "OpaqueData": "", "persistent": "false" }'
sns create-topic --name=prompt-processing-dev --attributes='{"push-endpoint": "kafka://172.24.10.50:9094", "OpaqueData": "", "persistent": "false" }'

# Set the Topic Configuration
s3api put-bucket-notification-configuration --bucket=rubin-pp-dev --notification-configuration=file://rubin-pp-dev-topic-config.json

# Validate the configuration
s3api get-bucket-notification-configuration --bucket=rubin-pp-dev
sns get-topic-attributes --topic-arn arn:aws:sns:default::pp-dev-microservice-202509
sns get-topic-attributes --topic-arn arn:aws:sns:default::prompt-processing-dev