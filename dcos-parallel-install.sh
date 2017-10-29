#!/bin/bash
source cluster.conf
PRIVKEY="${HOME}/.ssh/id_rsa"
COREUSER="core"

function parallel_ssh(){
  local members=${1}
  local command=${2}
  tfile=$(mktemp)
  echo "Running ${tfile} on ${members}"
  cat <<EOF >${tfile}
#!/bin/bash
exec > ${tfile}.log.\$\$ 2>&1
echo "Processing member \${1}"
ssh -t -i ${PRIVKEY} ${COREUSER}@\${1} "${command}"
EOF
  chmod +x ${tfile}
  for member in ${members}; do
    if [ ! -z ${3} ]; then 
      echo "Sleeping for ${3}"
      sleep ${3}
    fi
    tmux new-window "${tfile} ${member}"
  done
  #rm ${tfile}.*
}

function parallel_scp(){
  local members=${1}
  local files=${2}

  for member in ${members}; do
    echo "scp ${files} to ${member}"
    tmux new-window "scp -i ${PRIVKEY} ${files} ${COREUSER}@${member}:"
  done
}

function wait_sessions() {
  local max_wait=120
  local interval="30s"
  if [ ! -z ${1} ]; then interval=${1}; fi
  local wins=$(tmux list-sessions | cut -d' ' -f2)
  while [ ! "${wins}" == "1" ]; do
    sleep ${interval}
    (( max_wait-- ))
    wins=$(tmux list-sessions | cut -d' ' -f2)
    echo "Remaining tasks ${wins}"
    if [ ${max_wait} -le 0 ] ; then
      echo "Timeout waiting for all sessions to close."
      tmux kill-server
      exit 1
    fi
  done
}

# Main
for f in ${PRIVKEY}; do
    if [ ! -f ${f} ]; then
        echo "${f} not found."
        exit 1
    fi
done

echo "Starting tmux..."
tmux start-server
tmux new-session -d -s tester

echo "Scanning node public keys for SSH auth ..."
for i in ${NODES}; do
  ssh-keygen -R ${i}
  ssh-keyscan -H ${i} >> ${HOME}/.ssh/known_hosts
done

echo "Making sure we can SSH to all nodes ..."
parallel_ssh "${NODES}" "ls -l"
wait_sessions "5s"

echo "Scp-ing scripts to nodes ..."
parallel_scp "${NODES}" "cluster.conf scripts/all*"
parallel_scp "${BOOTSTRAP}" "scripts/boot*"
parallel_scp "${NODESM}" "scripts/master*"
parallel_scp "${NODESPRIV}" "scripts/private*"
parallel_scp "${NODESPUB}" "scripts/public*"
wait_sessions "5s"

echo "Quick bootstrap on all nodes"
parallel_ssh "${NODES}" "/home/${COREUSER}/all-01.sh"

echo "Preparing DC/OS binaries ..."
parallel_ssh "${BOOTSTRAP}" "sudo /home/${COREUSER}/boot-02.sh"
wait_sessions

echo "Installing master nodes ..."
parallel_ssh "${NODESM}" "sudo /home/${COREUSER}/master-02.sh" "1m"
wait_sessions "1m"
sleep 1m

echo "Installing private and public nodes ..."
parallel_ssh "${NODESPRIV}" "sudo /home/${COREUSER}/private-02.sh"
parallel_ssh "${NODESPUB}" "sudo /home/${COREUSER}/public-02.sh"
wait_sessions "1m"

echo "Shutting down tmux"
tmux kill-server
echo "Done"
