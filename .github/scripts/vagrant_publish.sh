#!/usr/bin/env bash
# This script publish vagrant boxes to hcp.vagrantcloud

date=$(date +%F)

vagrant cloud publish \
	           ${VAGRANT_ORG}/${PRODUCT}-${OS_NAME} \
                   $date virtualbox ${PRODUCT}-${OS_NAME}.box \
                   -d "Box with pre-installed ${PRODUCT}" \
                   --version-description "${PRODUCT}:${BOX_VERSION}" \
                   --release --short-description "Boxes for update testing" \
                   --force \
                   --no-private

