# usdf_deploy
Deployment configurations and scripts for the the data ingest from Rubin to the USDF.


# Background

We expect images from the summit to arrive at USDF by means of an PUT of an s3 object. In order to act upon these images, we expect

- a web notification that a new object has been PUT
- access to the s3 bucket (read only)
- credentials to update the butler database


# Deployment

Log into your k8s cluster. On USDF the two vclusters are https://k8s.slac.stanford.edu/usdf-embargo-dmz-dev and https://k8s.slac.stanford.edu/usdf-embargo-dmz for dev and prod respectively.

```
# obtain token to access secrets
export VAULT_ADDR=https://vault.slac.stanford.edu
vault login -method ldap -username <username>
# apply the k8s manifests
cd usdf-oga-dmz
make apply
```

The above will authenticate you against our vault instance so that you can obtain the most up-to-date secrets, download the passwords temporarily into your working directory, push the kubernetes manifests to the cluster and then subsequently remove the secrets.

