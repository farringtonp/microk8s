#!/bin/bash
set -ex

echo "Switching master to calico"

source $SNAP/actions/common/utils.sh
CA_CERT=/snap/core18/current/etc/ssl/certs/ca-certificates.crt

RESOURCES="$SNAP/upgrade-scripts/000-switch-to-calico/resources"
BACKUP_DIR="$SNAP_DATA/var/tmp/upgrades/000-switch-to-calico"

mkdir -p "$BACKUP_DIR"

mkdir -p "$BACKUP_DIR/args/cni-network/"
cp "$SNAP_DATA"/args/cni-network/* "$BACKUP_DIR/args/cni-network/" 2>/dev/null || true
find "$SNAP_DATA"/args/cni-network/* -not -name '*multus*' -exec rm -f {} \;
ARCH="$($SNAP/bin/uname -m)"
if [ "$ARCH" == "s390x" ]
then
  cp "$RESOURCES/calico.s390x.yaml" "$SNAP_DATA/args/cni-network/cni.yaml"
else
  cp "$RESOURCES/calico.yaml" "$SNAP_DATA/args/cni-network/cni.yaml"
fi

echo "Restarting services"
cp "$SNAP_DATA"/args/kube-apiserver "$BACKUP_DIR/args"
refresh_opt_in_config "allow-privileged" "true" kube-apiserver

# Reconfigure kubelet/containerd to pick up the new CNI config and binary.
cp "$SNAP_DATA"/args/kubelet "$BACKUP_DIR/args"
echo "Restarting kubelet"
refresh_opt_in_config "cni-bin-dir" "\${SNAP_DATA}/opt/cni/bin/" kubelet

cp "$SNAP_DATA"/args/containerd-template.toml "$BACKUP_DIR/args"
if grep -qE "bin_dir.*SNAP}\/" $SNAP_DATA/args/containerd-template.toml; then
  echo "Restarting containerd"
  "${SNAP}/bin/sed" -i 's;bin_dir = "${SNAP}/opt;bin_dir = "${SNAP_DATA}/opt;g' "$SNAP_DATA/args/containerd-template.toml"
  snapctl restart ${SNAP_NAME}.daemon-containerd
fi

cp "$SNAP_DATA"/args/kube-proxy "$BACKUP_DIR/args"
echo "Restarting kube proxy"
refresh_opt_in_config "cluster-cidr" "10.1.0.0/16" kube-proxy

if [ -e "$SNAP_DATA"/var/lock/lite.lock ]
then
  snapctl restart ${SNAP_NAME}.daemon-kubelite
else
  snapctl restart ${SNAP_NAME}.daemon-apiserver
  snapctl restart ${SNAP_NAME}.daemon-kubelet
  snapctl restart ${SNAP_NAME}.daemon-proxy
fi

set_service_not_expected_to_start flanneld
snapctl stop ${SNAP_NAME}.daemon-flanneld
remove_vxlan_interfaces

# Allow for services to restart
sleep 15
${SNAP}/microk8s-status.wrapper --wait-ready --timeout 30

KUBECTL="$SNAP/kubectl --kubeconfig=${SNAP_DATA}/credentials/client.config"
$KUBECTL apply -f "$SNAP_DATA/args/cni-network/cni.yaml"

echo "Calico is enabled"
