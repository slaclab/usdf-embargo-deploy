#Set S3 profile
profile=embargo-rw

# Alias s3api and sns commands
alias sns='apptainer exec /sdf/sw/s3/aws-cli_latest.sif aws --endpoint-url https://sdfembs3.sdf.slac.stanford.edu sns --region="" --profile=$profile'
alias s3api="apptainer exec /sdf/sw/s3/aws-cli_latest.sif aws --endpoint-url https://sdfembs3.sdf.slac.stanford.edu s3api --profile=$profile"

# Clear the bucket notification configuration
s3api --profile=$profile put-bucket-notification-configuration --bucket=rubin-summit --notification-configuration=file://blank-topic-config.json

# Delete the current topics and create a new ones
sns delete-topic --topic-arn=arn:aws:sns:rubin-zg::rubin-ingest-embargo-new-4
sns delete-topic --topic-arn=arn:aws:sns:sdfembargo::rubin-summit-notification-8

# Sleep to allow topics to clear.
echo "Starting sleep for 60 seconds to allow topics to clear"
sleep 60
echo "Sleep done"

# Create new topics
sns create-topic --name=rubin-summit-notification-8 --attributes='{"push-endpoint": "kafka://172.24.10.54:9094", "OpaqueData": "", "persistent": "true", "max_retries": "3", "retry_sleep_duration": "10", "time_to_live": "60"}'

# Set the Topic Configuration
s3api put-bucket-notification-configuration --bucket=rubin-summit --notification-configuration=file://rubin-summit-topic-config.json

# Validate the configuration
s3api get-bucket-notification-configuration --bucket=rubin-summit
sns get-topic-attributes --topic-arn arn:aws:sns:sdfembargo::rubin-summit-notification-8
