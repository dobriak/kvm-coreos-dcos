#!/bin/bash
if [ -z "${1}" ]; then
    echo "Missing argument. Format:"
    echo "  ${0} key1:value1[,keyX:valueX,...] [-f]"
    exit 1
fi
if [ -f /var/lib/dcos/mesos-slave-common ]; then
    if [ "${2}" != "-f" ]; then
        echo "mesos-slave-common exists. Use -f to overwrite."
        exit 1
    fi
fi
# Example: hospital:kansas
sudo su -c "echo MESOS_ATTRIBUTES=${1} > /var/lib/dcos/mesos-slave-common"
sudo rm -rf /var/lib/mesos/slave/meta/slaves/latest
sudo systemctl restart dcos-mesos-slave.service
echo "Attributes set:"
echo ${1}
