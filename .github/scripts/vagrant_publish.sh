#!/usr/bin/env bash
# This script publish vagrant boxes to hcp.vagrantcloud

hcp auth login --client-id=$HCP_CLIENT_ID --client-secret=$HCP_CLIENT_SECRET
_VAGRANT_CLOUD_TOKEN="$(hcp auth print-access-token)"

_ORG=${VAGRANT_ORG}
_BOX="${PRODUCT}-${OS_NAME}"
_VERSION=${BOX_VERSION}
_PROVIDER=virtualbox
_ARCHITECTURE=amd64
_CHECKSUM="$(sha256sum ${_BOX}.box | awk '{ print $1 }')"

curl -skL \
  --request POST \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer $_VAGRANT_CLOUD_TOKEN" \
  --data "{ \"box\": { \"username\": \"$_ORG\", \"name\": \"$_BOX\", \"is_private\": false } }" \
  https://app.vagrantup.com/api/v2/boxes | jq .

curl -skL \
  --request POST \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer $_VAGRANT_CLOUD_TOKEN" \
  --data "{ \"version\": { \"version\": \"$_VERSION\" } }" \
  https://app.vagrantup.com/api/v2/box/$_ORG/$_BOX/versions | jq .

curl -skL \
  --request DELETE \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer $_VAGRANT_CLOUD_TOKEN" \
  https://app.vagrantup.com/api/v2/box/$_ORG/$_BOX/version/$_VERSION/provider/$_PROVIDER/$_ARCHITECTURE | jq .

curl -skL \
  --request POST \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer $_VAGRANT_CLOUD_TOKEN" \
  --data "{ \"provider\": { \"name\": \"$_PROVIDER\", \"checksum_type\": \"sha256\", \"checksum\": \"$_CHECKSUM\", \"architecture\": \"$_ARCHITECTURE\", \"default_architecture\": true } }" \
  https://app.vagrantup.com/api/v2/box/$_ORG/$_BOX/version/$_VERSION/providers | jq .

_UPLOAD_PATH=$(curl -skL \
  --request GET \
  --header "Authorization: Bearer $_VAGRANT_CLOUD_TOKEN" \
  https://app.vagrantup.com/api/v2/box/$_ORG/$_BOX/version/$_VERSION/provider/$_PROVIDER/$_ARCHITECTURE/upload | jq -r .upload_path)

curl -skL \
  --request PUT \
  --header "Connection: keep-alive" \
  --upload-file ${_BOX}.box \
  $_UPLOAD_PATH | jq .

curl -skL \
  --request PUT \
  --header "Authorization: Bearer $_VAGRANT_CLOUD_TOKEN" \
  https://app.vagrantup.com/api/v2/box/$_ORG/$_BOX/version/$_VERSION/release | jq .
