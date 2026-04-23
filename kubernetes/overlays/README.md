Obtain your Kubernetes token via https://k8s.slac.stanford.edu/{usdf-embargo-dmz,usdf-embargo-dmz-dev}, then deploy each environment by changing into its overlay directory and running:

```bash
vault login -method=ldap
make apply
```

Overlays include **summit**, **summit-new**, **bts**, **tts**, **sts**, **lfa**, **pp-dev**, and **test**.

- **`test`** — embargo-butler on **usdf-embargo-dmz-dev** (namespace `test`), SQLite Butler on PVC for integration testing. See **[test/DEVELOPER-TESTING.md](test/DEVELOPER-TESTING.md)** and service source in [embargo-butler](https://github.com/lsst-dm/embargo-butler).

The top-level **`Makefile`** in this directory applies a subset of environments; **`test`** (like **pp-dev**) is applied only when you **`cd test && make apply`** explicitly.
