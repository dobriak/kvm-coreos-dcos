#!/bin/bash
source cluster.conf
IPDETECT='ip addr show eth0 | grep -Eo "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | head -1'
IPDETECT_PUB='ip addr show eth1 | grep -Eo "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" | head -1'
echo "Downloading installer"
wget -O dcos_generate_config.sh ${DOWNLOAD_URL}

echo "Installing nginx"
docker pull nginx

RESOLVER_IP=$(cat /etc/resolv.conf | grep nameserver | cut -d' ' -f2)
resolvers=""
for ip in ${RESOLVER_IP}; do
    resolvers="${resolvers}- ${ip}"$'\n'
done

mkdir genconf

echo "Writing ip-detect"
cat <<EOF >genconf/ip-detect
#!/bin/bash
set -o nounset -o errexit
${IPDETECT}
EOF

echo "Writing ip-detect-public"
cat <<EOF >genconf/ip-detect-public
#!/bin/bash
set -o nounset -o errexit
${IPDETECT_PUB}
EOF

EXTRA_MASTERS=""
if [ -n "${MASTER2}" ] && [ -n "${MASTER3}" ]; then
  EXTRA_MASTERS="
- ${MASTER2}
- ${MASTER3}
"
fi

BOOTSTRAP_IP=$(bash genconf/ip-detect)
echo "Writing config.yaml"
cat <<EOF >genconf/config.yaml
bootstrap_url: http://${BOOTSTRAP_IP}:${BOOTSTRAP_PORT}
cluster_name: julians
exhibitor_storage_backend: static
master_discovery: static
telemetry_enabled: false
security: permissive
rexray_config_method: file
rexray_config_filename: rexray.yaml
ip_detect_public_filename: genconf/ip-detect-public
master_list:
- ${MASTER1}
${EXTRA_MASTERS}
resolvers:
${resolvers}
superuser_username: bootstrapuser
EOF

echo "Writing rexray.yaml"
cat <<EOF >genconf/rexray.yaml
loglevel: info
storageDrivers:
  - ec2
volume:
  unmount:
    ignoreusedcount: true
EOF

echo "Setting superuser password to ${SUPASSWORD}"
sudo bash dcos_generate_config.sh --set-superuser-password ${SUPASSWORD}

echo "Generating binaries"
sudo bash dcos_generate_config.sh

echo "Running nginx on http://${BOOTSTRAP_IP}:${BOOTSTRAP_PORT}"
docker run -d -p ${BOOTSTRAP_PORT}:80 -v $PWD/genconf/serve:/usr/share/nginx/html:ro nginx

echo "Done"
