echo "=== Kafka enqueue logs ===" && \
	kubectl logs -n test deploy/embargo-butler-enqueue --since=10m | tail -5 && \
	echo "=== Redis state ===" && \
	kubectl exec -n test redis-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning LLEN QUEUE:embargo@rubin-summit' && \
	kubectl exec -n test redis-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning HGETALL REC:embargo@rubin-summit' && \
	echo "=== Ingest logs ===" && \
	kubectl logs -n test deploy/embargo-butler-ingest --since=10m --tail=20 && \
	echo "=== Butler rows ===" && \
	kubectl exec -n test deploy/embargo-butler-ingest -- bash -lc 'source loadLSST.bash && setup lsst_distrib && butler query-datasets /butler raw --where "instrument='"'"'LSSTCam'"'"' and day_obs=20260324 and exposure.seq_num=404" --collections LSSTCam/raw/all 2>&1 | tail -10'
