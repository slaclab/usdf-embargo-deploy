# usdf_deploy
Deployment configurations and scripts for the the data ingest from Rubin to the USDF.


# Background

We expect images from the summit (or a test stand) to arrive at USDF by means of an PUT of an s3 object.
A set of services is notified of that PUT and handles the images, ingesting them into a Butler repository and defining visits for them.

In the short term, the services can also optionally register the images with Rucio for replication.

In order to act upon these images, we expect

- a web notification that a new object has been PUT
- access to the s3 bucket (read only)
- credentials to update the butler database

See [Section 5 of DMTN-143](https://dmtn-143.lsst.io/#implementation) for more details.

# Bucket Policies

The buckets are paired, with a raw data bucket and a user data products bucket for each environment.
This enables each environment to work the same way as the Summit, enabling more end-to-end testing.

The raw data bucket owner credentials are given to the Camera subsystem to enable writing directly to the bucket.
Eventually the ``transfer_embargo`` service that moves datasets from the embargo repo to the un-embargoed main repo will also have write credentials in order to remove datasets.

The ``rubin-summit-users`` bucket owner credentials are given to all users.
These ``rubin-summit-users`` credentials are then given read access to all buckets and read/write access to all ``-users`` buckets.
The use of a single set of credentials means that users don't need to switch credentials when going from environment to environment.

The bucket policies are applied using the AWS s3api.
```
alias s3api="apptainer exec /sdf/sw/s3/aws-cli_latest.sif aws --endpoint-url https://s3dfrgw.slac.stanford.edu s3api"
s3api --profile=$PROFILE put-bucket-policy --bucket $BUCKET --policy file:$FILE
```
where the PROFILE specifies the credentials for the bucket owner.

The bucket policies should only need to be set once, but they may change over time.

# Bucket Notifications

Setting up bucket notifications in S3 (including Ceph) requires two things: creating a notification topic and configuring the bucket to notify on that topic.

Creating a topic uses parameters specified in the [Ceph Bucket Notifications documentation](https://docs.ceph.com/en/latest/radosgw/notifications/#create-a-topic).
For a Kakfa or webhook topic, make sure to specify ``push-endpoint`` as a URI.
The auto-ingest system expects ``persistent=true`` in order to allow Ceph to return status as soon as an object is created, without waiting for the notification.
The auto-ingest system also expects webhooks to have an ``OpaqueData`` item which matches the ``notification`` secret in ``vault.slac.stanford.edu``.
Sample command:
```
alias sns='singularity exec /sdf/sw/s3/aws-cli_latest.sif aws --endpoint-url https://s3dfrgw.slac.stanford.edu sns --region=""'
sns create-topic --name=rubin-summit --attributes='{"push-endpoint": "http://172.24.5.174:8080/notify", "OpaqueData": "GETFROMVAULT", "persistent": "true" }'
```
Each topic is assigned an "ARN" by Ceph with its name as the last component for future reference.

Next, one or more notifications need to be configured for the bucket.
Each one links bucket events with topics via the ARN.
Sample JSON:
```
{
    "TopicConfigurations": [
        {
            "Id": "rubin-prompt-processing-prod",
            "TopicArn": "arn:aws:sns:default::rubin-prompt-processing-prod",
            "Events": [
                "s3:ObjectCreated:*"
            ]
        },
        {
            "Id": "rubin-summit-to-http",
            "TopicArn": "arn:aws:sns:default::rubin-summit",
            "Events": [
                "s3:ObjectCreated:*"
            ]
        }
    ]
}
```
Sample command:
```
s3api --profile=wsummit put-bucket-notification-configuration --bucket=rubin-summit --notification-configuration=file:///path/to/my/config.json
```

The file path must be visible to the apptainer container, which usually means that it must be under ``/sdf/home`` (and not symlinked from ``/sdf/data``).

Note that changing a topic's attributes does not take effect until the bucket notification configurations are rewritten, even if they're updated with the exact same JSON.

# Deployment Structure

The ingest services are comprised of a Redis pod, a single "enqueue" pod, a single "idle" cleanup pod, a single "presence" pod, and a set of one or more "ingest" pods.

Redis is the inter-pod communications mechanism via persistent queues, and it also acts as the monitoring database.

The "enqueue" pod receives bucket notification webhooks and immediately writes the embedded object store keys to a Redis queue.

The "ingest" pods take the object store keys from the main queue, copy them atomically to a per-pod worker queue, and process them, removing them from the worker queue when done.

The "idle" pod looks for worker queues that have not been modified in a while, indicating that the corresponding "ingest" pod has died.
It pushes the contents of such queues back onto the main queue so that they're available to other "ingest" pods.

The "presence" pod provides a microservice for Prompt Processing to look up image paths based on group and snap IDs.

Each pod type has a deployment YAML.
There is also a ``ns.yaml`` that defines the namespace for each environment.
A ``kustomization.yaml`` script adjusts these per environment.
A common ``Makefile`` retrieves secrets from vault.slac.stanford.edu, dumps or applies the customized YAML, and cleans up the secrets.

# Deployment Process

Log into the k8s cluster.
On USDF the two vclusters are https://k8s.slac.stanford.edu/usdf-embargo-dmz-dev and https://k8s.slac.stanford.edu/usdf-embargo-dmz for dev and prod respectively.

Obtain a token to access the secrets in vault:
```
# obtain token to access secrets
export VAULT_ADDR=https://vault.slac.stanford.edu
vault login -method ldap username=<username>
```
Alternatively, especially for those without Windows LDAP accounts, copy the token from the web interface at vault.slac.stanford.edu and provide it to ``vault login``.

Apply the Kubernetes manifests:
```
cd kubernetes/overlays
make apply
```
The above will authenticate you against our vault instance so that you can obtain the most up-to-date secrets, download the passwords temporarily into your working directory, push the kubernetes manifests to the cluster and then subsequently remove the secrets.
You can also apply one environment at a time.

The external (but SLAC-internal) IP address of the ``-butler-enqueue`` service needs to be used in the endpoint address for the webhook notification topic for the corresponding raw data bucket (e.g. ``http://172.24.5.180:8080/notify``).
The OpaqueData value for that notification topic should match the notification secret in vault.

# Monitoring the Services

The Loki log explorer at grafana.slac.stanford.edu is the best way to monitor the services for now.
Select the ``vcluster--usdf-embargo-dmz`` namespace and (usually) the ``ingest`` container.
Searching for "ERROR" may be helpful.

# Scaling the Deployment

If the latency between delivery of the image file and ingest seems high, increasing the number of ingest pods should help.

``kubectl scale --replicas=N deployment/{env}-butler-ingest`` can be used to dynamically scale the number of ingest pods up or down.
Editing the deployment to change the number of replicas has the same effect.
Note that these changes only persist until the next ``make apply``.

# Software Update Process

1. After updating the service code in https://github.com/lsst-dm/embargo-butler, tag main with a ``vX.Y.Z`` semantic version.
   This will automatically build and publish containers with that tag.
1. Update the ``kustomization.yaml`` to select that tag for the environments and pods where it is needed.
1. Apply and ensure that the deployment is correct in the dev cluster.
   ``/sdf/home/k/ktl/ingest_trigger/trigger_ingest.py`` may be of use in testing.
1. Commit and merge the deployment update.  Note that PRs need to be manually set to go against the ``slaclab`` repo ``main`` branch, since it is a fork.
1. Apply and ensure that the deployment is correct in the prod cluster.
