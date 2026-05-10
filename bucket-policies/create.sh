# Notifications

for i in bts sts summit tts; do
    service=${i/summit/embargo}
    secret=$(vault kv get --field=notification secret/rubin/usdf-embargo-dmz/$i)
    ip=$(kubectl get -n $i service ${service}-butler-enqueue -o json \
	| jq .status.loadBalancer.ingress[0].ip)
    sns delete-topic --topic-arn arn:aws:sns:default::rubin-$i || echo "No existing topic rubin-$i"
    sns create-topic --name rubin-$i \
	    --parameters "{ \"push-endpoint\": \"http://${ip}:8080/notify\", \"OpaqueData\": \"${secret}\" }"
    # This next is needed to clear out any old configuration
    s3api put-bucket-notification-configuration --bucket rubin-$i \
	    --notification-configuration "{}"
    s3api put-bucket-notification-configuration --bucket rubin-$i \
	    --notification-configuration "{ \"TopicConfiguration\": { \"Id\": \"rubin-${i}-to-http\", \"Events\": [ \"s3:ObjectCreated:*\" ], \"Event\": \"s3:ObjectCreated:*\", \"Topic\": \"arn:aws:sns:default::rubin-${i}\" } }"
done

# Bucket Policies

for i in bts bts-users sts summit tts tts-users; do
    s3api put-bucket-policy --bucket rubin-$i --policy "$(< ${i}-policy.json)"
done
