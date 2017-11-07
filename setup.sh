#!/bin/bash
#set -ex
source cluster.conf

function initialSetup() {
    local disk
    if [ ! -d ${image_dir} ]; then
        mkdir ${image_dir}
        pushd ${image_dir}
            wget https://stable.release.core-os.net/amd64-usr/1235.9.0/coreos_production_qemu_image.img.bz2
            bunzip2 coreos_production_qemu_image.img.bz2
        popd
    fi

    for node in ${nodes}; do
        disk=${image_dir}/${node}-disk.qcow2
        if [ ! -f ${disk} ]; then
            qemu-img create -f qcow2 -b ${image_dir}/coreos_production_qemu_image.img ${disk} 15G
        fi
    done
    
    if [ ! -d ${domain_dir} ]; then
        mkdir -p ${domain_dir}
    fi
    
    # If running in enforcing SE mode
    #semanage fcontext -a -t virt_content_t ${domain_dir}
    #restorecon -R ${domain_dir}

}

function createIps() {
    for node in ${nodes}; do
        virsh net-update --network "${NATNET}" add-last ip-dhcp-host \
            --xml "<host mac='${nics[${node}mac]}' ip='${nics[${node}ip]}' />" \
            --live --config
    done
    #for node in m1 p1; do
    #    virsh net-update --network "${BRNET}" add-last ip-dhcp-host \
    #        --xml "<host mac='${nics[${node}macx]}' ip='${nics[${node}ipx]}' />" \
    #        --live --config
    #done
}

function writeIgnition() {
    local ext_nic
    for node in ${nodes}; do
        ext_nic=""
        if [[ "m1 p1" == *"${node}"* ]]; then
            ext_nic=",{ \"name\": \"00-eth1.network\", \"contents\": \"[Match]\nMACAddress=${nics[${node}macx]}\n\n[Network]\nAddress=${nics[${node}ipx]}\nDNS=${DNS}\" }"
        fi

        cat > ${domain_dir}/${node}-provision.ign <<EOF
{
  "ignition": {
    "version": "2.0.0",
    "config": {}
  },
  "storage": {
    "files": [
      {
        "filesystem": "root",
        "path": "/etc/hostname",
        "contents": {
          "source": "data:,${node}",
          "verification": {}
        },
        "user": {},
        "group": {}
      }
    ]
  },
  "systemd": {},
  "networkd": {
    "units": [
      {
        "name": "00-eth0.network",
        "contents": "[Match]\nMACAddress=${nics[${node}mac]}\n\n[Network]\nAddress=${nics[${node}ip]}\nGateway=${GWY}\nDNS=${DNS}"
      }${ext_nic}
    ]
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": [
          "${sshkey}"
        ]
      }
    ]
  }
}
EOF
    done

}

function generateDomains() {

    local ram vcpus pub_bridge domain
    for node in ${nodes}; do
        ram=2048
        vcpus=1
        pub_bridge=""
        domain=${domain_dir}/${node}-domain.xml
        if [[ "a1 a2" == *"${node}"* ]]; then
            ram=4096
            vcpus=2
        fi
        if [[ "m1 p1" == *"${node}"* ]]; then
            pub_bridge="--network bridge=${BRBR},mac=${nics[${node}macx]}"
        fi

        virt-install --connect qemu:///system \
                     --import \
                     --name ${node} \
                     --ram ${ram} --vcpus ${vcpus} \
                     --os-type=linux \
                     --os-variant=virtio26 \
                     --disk path=${image_dir}/${node}-disk.qcow2,format=qcow2,bus=virtio \
                     --network bridge=${NATBR},mac=${nics[${node}mac]} ${pub_bridge} \
                     --vnc --noautoconsole \
                     --print-xml > ${domain}
        sed -ie 's|type="kvm"|type="kvm" xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0"|' ${domain}
        sed -i "/<\/devices>/a <qemu:commandline>\n  <qemu:arg value='-fw_cfg'/>\n  <qemu:arg value='name=opt/com.coreos/config,file=${domain_dir}/${node}-provision.ign'/>\n</qemu:commandline>" ${domain}
    done
}

function startDomains() {
    local domain
    for node in ${nodes}; do
        domain=${domain_dir}/${node}-domain.xml
        virsh define ${domain}
        virsh start ${node}
    done
}

function cleanDomains() {
    local disk
    for node in ${nodes}; do
        if virsh list | grep ${node}; then
            disk=${image_dir}/${node}-disk.qcow2
            virsh destroy ${node} || echo "ok"
            virsh undefine ${node} || echo "ok"
            rm -f ${disk} || echo "ok"
            virsh net-update --network ${NATNET} delete ip-dhcp-host --xml "<host mac='${nics[${node}mac]}' ip='${nics[${node}ip]}' />" --live --config || echo "ok"
        fi
    done
}


function upDomains() {
    local version=${1}
    echo "Rehydrating disks"
    for d in ${nodes}; do
        echo ${d}
        cp ${image_dir}/${d}-${version}.qcow2 ${image_dir}/${d}-disk.qcow2
    done
}


if (( ${EUID} != 0 )); then
    echo "Please run as root"
    exit 1
fi
nodes="b m1 a1 a2 p1"
NATNET="default"
BRNET="host-bridge"
NATBR="virbr0"
BRBR="br0"
GWY="192.168.122.1"
DNS="192.168.1.5"

declare -A nics
nics[bmac]="52:54:00:fe:b3:10" ; nics[bip]="192.168.122.110"
nics[m1mac]="52:54:00:fe:b3:20" ; nics[m1ip]="192.168.122.120"
nics[m1macx]="52:54:00:fe:b3:2a" ; nics[m1ipx]="192.168.1.222"
nics[a1mac]="52:54:00:fe:b3:31" ; nics[a1ip]="192.168.122.131"
nics[a2mac]="52:54:00:fe:b3:32" ; nics[a2ip]="192.168.122.132"
nics[p1mac]="52:54:00:fe:b3:40" ; nics[p1ip]="192.168.122.140"
nics[p1macx]="52:54:00:fe:b3:4a" ; nics[p1ipx]="192.168.1.223"

sshkey=$(cat ${PUBKEY})
domain_dir=/var/lib/libvirt/container-linux/dcos
image_dir=/var/lib/libvirt/images/container-linux

if [ "${1}" == "clean" ]; then
    cleanDomains
    echo "Done"    
    exit 0
fi
if [ "${1}" == "up" ]; then
    # No need for bootstrap
    nodes="m1 a1 a2 p1"
    upDomains 1101
	initialSetup
	createIps
	writeIgnition
	generateDomains
	startDomains
    echo "1m sleep"
	sleep 1m
    echo "Getting public keys"
	for i in ${NODESM} ${NODESPUB} ${NODESPRIV}; do
	  sudo -u ${USER} ssh-keygen -R ${i}
	  sudo -u ${USER} ssh-keyscan -H ${i} >> /home/${USER}/.ssh/known_hosts
	done
    echo "Restarting DCOS master"
    for master in ${NODESM}; do
        sudo -u ${USER} ssh core@${master} sudo systemctl restart dcos.target
    done
    echo "Done"
    exit 0
fi


initialSetup
createIps
writeIgnition
generateDomains
startDomains

echo "Done"
