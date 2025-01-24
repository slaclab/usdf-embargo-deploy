sns create-topic --name=or5-notification --region default --attributes='{"push-endpoint": "http://172.24.5.162:8080/notify", "OpaqueData": "GET FROM VAULT", "persistent": "false" }'
