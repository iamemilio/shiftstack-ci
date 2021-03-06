#!/usr/bin/env bash

set -e

CONFIG=${CONFIG:-cluster_config.sh}
if [ ! -r "$CONFIG" ]; then
    echo "Could not find cluster configuration file."
    echo "Make sure $CONFIG file exists in the shiftstack-ci directory and that it is readable"
    exit 1
fi
source ${CONFIG}

set -x

# check whether we have a free floating IP
FLOATING_IP=$(openstack floating ip list --status DOWN --network $OPENSTACK_EXTERNAL_NETWORK --long --format value -c "Floating IP Address" -c Description | awk 'NF<=1 && NR==1 {print}')

# create new floating ip if doesn't exist
if [ -z "$FLOATING_IP" ]; then
    FLOATING_IP=$(openstack floating ip create $OPENSTACK_EXTERNAL_NETWORK --format value --column floating_ip_address)
fi

hosts="# Generated by shiftstack for $CLUSTER_NAME - Do not edit
$FLOATING_IP api.${CLUSTER_NAME}.${BASE_DOMAIN}
$FLOATING_IP console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$FLOATING_IP integrated-oauth-server-openshift-authentication.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$FLOATING_IP oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$FLOATING_IP prometheus-k8s-openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$FLOATING_IP grafana-openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
# End of $CLUSTER_NAME nodes"

old_hosts=$(awk "/# Generated by shiftstack for $CLUSTER_NAME - Do not edit/,/# End of $CLUSTER_NAME nodes/" /etc/hosts)

if [ "${hosts}" != "${old_hosts}" ]; then
  echo Updating hosts file
  sudo sed -i "/# Generated by shiftstack for $CLUSTER_NAME - Do not edit/,/# End of $CLUSTER_NAME nodes/d" /etc/hosts
  echo "$hosts" | sudo tee -a /etc/hosts
fi

ssh_config="# Generated by shiftstack for $CLUSTER_NAME - Do not edit
Host service-vm-$CLUSTER_NAME
    Hostname $FLOATING_IP
    User core
    Port 22
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
# End of $CLUSTER_NAME nodes"

old_ssh_config=$(awk "/# Generated by shiftstack for $CLUSTER_NAME - Do not edit/,/# End of $CLUSTER_NAME nodes/" $HOME/.ssh/config)
if [ "${ssh_config}" != "${old_ssh_config}" ]; then
  echo Updating ssh config file
  sed -i "/# Generated by shiftstack for $CLUSTER_NAME - Do not edit/,/# End of $CLUSTER_NAME nodes/d" $HOME/.ssh/config
  echo "$ssh_config" >>  $HOME/.ssh/config
fi

if [ ! -d $CLUSTER_NAME ]; then
    mkdir -p $CLUSTER_NAME
fi

: "${OPENSTACK_WORKER_FLAVOR:=${OPENSTACK_FLAVOR}}"

if [ ! -f $CLUSTER_NAME/install-config.yaml ]; then
    export CLUSTER_ID=$(uuidgen --random)
    cat > $CLUSTER_NAME/install-config.yaml << EOF
apiVersion: v1beta3
baseDomain: ${BASE_DOMAIN}
clusterID:  ${CLUSTER_ID}
compute:
- hyperthreading: Enabled
  name: worker
  platform:
    openstack:
      type: ${OPENSTACK_WORKER_FLAVOR}
  replicas: ${WORKER_COUNT}
controlPlane:
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: ${MASTER_COUNT}
metadata:
  name: ${CLUSTER_NAME}
networking:
  clusterNetworks:
  - cidr:             10.128.0.0/14
    hostSubnetLength: 9
  serviceCIDR: 172.30.0.0/16
  machineCIDR: 10.0.128.0/17
  type:        OpenshiftSDN
platform:
  openstack:
    cloud:            ${OS_CLOUD}
    externalNetwork:  ${OPENSTACK_EXTERNAL_NETWORK}
    region:           ${OPENSTACK_REGION}
    computeFlavor:    ${OPENSTACK_FLAVOR}
    lbFloatingIP:     ${FLOATING_IP}
pullSecret: |
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
fi


$GOPATH/src/github.com/openshift/installer/bin/openshift-install --log-level=debug ${1:-create} ${2:-cluster} --dir $CLUSTER_NAME
