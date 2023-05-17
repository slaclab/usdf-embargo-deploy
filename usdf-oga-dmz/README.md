obtain your k8s token via https://k8s.slac.stanford.edu/{usdf-embargo-dmz,usdf-embargo-dmz-dev}, and then deploy each separate environment by cd'ing into its directory and running

vault login -method=ldap 
make apply


