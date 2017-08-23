#!/bin/bash

# Required variables:
# nodes_os - operating system (centos7, trusty, xenial)
# node_hostname - hostname of this node (mynode)
# node_domain - domainname of this node (mydomain)
# cluster_name - clustername (used to classify this node)
# config_host - IP/hostname of salt-master
# instance_cloud_init - cloud-init script for instance
# saltversion - version of salt

# Redirect all outputs
exec > >(tee -i /tmp/cloud-init-bootstrap.log) 2>&1
set -xe

echo "Environment variables:"
env

# Send signal to heat wait condition
# param:
#   $1 - status to send ("FAILURE" or "SUCCESS"
#   $2 - msg
#
#   AWS parameters:
# aws_resource
# aws_stack
# aws_region

function wait_condition_send() {
  local status=${1:-SUCCESS}
  local reason=${2:-empty}
  local data_binary="{\"status\": \"$status\", \"reason\": \"$reason\"}"
  echo "Sending signal to wait condition: $data_binary"
  if [ -z "$wait_condition_notify" ]; then
    # AWS
    if [ "$status" == "SUCCESS" ]; then
      aws_status="true"
      cfn-signal -s "$aws_status" --resource "$aws_resource" --stack "$aws_stack" --region "$aws_region"
    else
      aws_status="false"
      echo "SHOULD SEND FAILED SIGNAL"
      #cfn-signal -s "$aws_status" --resource "$aws_resource" --stack "$aws_stack" --region "$aws_region"
      exit 1
    fi
    else
      # Heat
      $wait_condition_notify -k --data-binary "$data_binary"
    fi

  if [ "$status" == "FAILURE" ]; then
    exit 1
  fi
}

# Add wrapper to apt-get to avoid race conditions
# with cron jobs running 'unattended-upgrades' script
aptget_wrapper() {
  local apt_wrapper_timeout=300
  local start_time=$(date '+%s')
  local fin_time=$((start_time + apt_wrapper_timeout))
  while true; do
    if (( "$(date '+%s')" > fin_time )); then
      msg="Timeout exceeded ${apt_wrapper_timeout} s. Lock files are still not released. Terminating..."
      wait_condition_send "FAILURE" "$msg"
    fi
    if fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
      echo "Waiting while another apt/dpkg process releases locks ..."
      sleep 30
      continue
    else
      apt-get $@
      break
    fi
  done
}

# Set default salt version
if [ -z "$saltversion" ]; then
	saltversion="2016.3"
fi
echo "Using Salt version $saltversion"

# Install cfn-signal is AWS
if [ ! -z "$aws_instance_id" ]; then
	apt-get update
	apt-get install -y python-pip
	pip install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz
fi

echo "Preparing base OS ..."
case "$node_os" in
    trusty)
        which wget > /dev/null || (aptget_wrapper update; aptget_wrapper install -y wget)

        echo "deb [arch=amd64] http://apt-mk.mirantis.com/trusty nightly salt extra" > /etc/apt/sources.list.d/mcp_salt.list
        wget -O - http://apt-mk.mirantis.com/public.gpg | apt-key add - || wait_condition_send "FAILURE" "Failed to add apt-mk key."

        echo "deb http://repo.saltstack.com/apt/ubuntu/14.04/amd64/$saltversion trusty main" > /etc/apt/sources.list.d/saltstack.list
        wget -O - "https://repo.saltstack.com/apt/ubuntu/14.04/amd64/$saltversion/SALTSTACK-GPG-KEY.pub" | apt-key add - || wait_condition_send "FAILURE" "Failed to add salt apt key."

        aptget_wrapper clean
        aptget_wrapper update
        aptget_wrapper install -y salt-common
        aptget_wrapper install -y salt-minion
        ;;
    xenial)
        which wget > /dev/null || (aptget_wrapper update; aptget_wrapper install -y wget)

        echo "deb [arch=amd64] http://apt-mk.mirantis.com/xenial nightly salt extra" > /etc/apt/sources.list.d/mcp_salt.list
        wget -O - http://apt-mk.mirantis.com/public.gpg | apt-key add - || wait_condition_send "FAILURE" "Failed to add apt-mk key."

        echo "deb http://repo.saltstack.com/apt/ubuntu/16.04/amd64/$saltversion xenial main" > /etc/apt/sources.list.d/saltstack.list
        wget -O - "https://repo.saltstack.com/apt/ubuntu/16.04/amd64/$saltversion/SALTSTACK-GPG-KEY.pub" | apt-key add - || wait_condition_send "FAILURE" "Failed to add saltstack apt key."

        aptget_wrapper clean
        aptget_wrapper update
        aptget_wrapper install -y salt-minion
        ;;
    rhel|centos|centos7|centos7|rhel6|rhel7)
        curl -L https://bootstrap.saltstack.com -o install_salt.sh
	if [ -z "$bootstrap_salt_opts" ]; then
		bootstrap-salt_opts="- stable $saltversion"
	fi
        sudo sh install_salt.sh -i "$node_hostname.$node_domain" -A "$config_host" "$bootstrap_saltstack_opts"
        ;;
    *)
        msg="OS '$node_os' is not supported."
        wait_condition_send "FAILURE" "$msg"
esac

echo "Configuring Salt minion ..."
[ ! -d /etc/salt/minion.d ] && mkdir -p /etc/salt/minion.d
echo -e "id: $node_hostname.$node_domain\nmaster: $config_host" > /etc/salt/minion.d/minion.conf

service salt-minion restart || wait_condition_send "FAILURE" "Failed to restart salt-minion service."


if [ "$salt_master" == 'yes' ]; then
  # Required variables for salt-master
  # nodes_os - operating system (centos7, trusty, xenial)
  # node_hostname - hostname of this node (mynode)
  # node_domain - domainname of this node (mydomain)
  # cluster_name - clustername, used to classify this node (virtual_mcp11_k8s)
  # config_host - IP/hostname of salt-master (192.168.0.1)
  #
  # private_key - SSH private key, used to clone reclass model
  # reclass_address - address of reclass model (https://github.com/user/repo.git)
  # reclass_branch - branch of reclass model (master)

  echo "Installing salt master ..."
  aptget_wrapper install -y reclass git
  aptget_wrapper install -y salt-master

  [ ! -d /root/.ssh ] && mkdir -p /root/.ssh

  if [ "$private_key" != "" ]; then
  cat << 'EOF' > /root/.ssh/id_rsa
$private_key
EOF
  chmod 400 /root/.ssh/id_rsa
  fi

  [ ! -d /etc/salt/master.d ] && mkdir -p /etc/salt/master.d
  cat << 'EOF' > /etc/salt/master.d/master.conf
file_roots:
  base:
  - /usr/share/salt-formulas/env
pillar_opts: False
open_mode: True
reclass: &reclass
  storage_type: yaml_fs
  inventory_base_uri: /srv/salt/reclass
ext_pillar:
  - reclass: *reclass
master_tops:
  reclass: *reclass
EOF

  echo "Configuring reclass ..."
  ssh-keyscan -H github.com >> ~/.ssh/known_hosts || wait_condition_send "FAILURE" "Failed to scan github.com key."
  set -e

  if [ ! -d "/srv/salt/reclass" ]; then
    if echo $reclass_branch | egrep -q "^refs"; then
        git clone $reclass_address /srv/salt/reclass
        cd /srv/salt/reclass
        git fetch $reclass_address $reclass_branch && git checkout FETCH_HEAD
        git submodule init
        git submodule update --recursive
        cd -
    else
        git clone -b $reclass_branch --recurse-submodules $reclass_address /srv/salt/reclass
    fi
  else
    echo "/srv/salt/reclass/ already exists, skipping clone"
  fi
  set +e
  mkdir -p /srv/salt/reclass/classes/service

  mkdir -p /srv/salt/reclass/nodes/_generated

echo "classes:
- cluster.$cluster_name.infra.config
parameters:
  _param:
    linux_system_codename: xenial
    reclass_data_revision: $reclass_branch
    reclass_data_repository: $reclass_address
    cluster_name: $cluster_name
    cluster_domain: $node_domain
  linux:
    system:
      name: $node_hostname
      domain: $node_domain
  reclass:
    storage:
      data_source:
        engine: local
" > /srv/salt/reclass/nodes/_generated/$node_hostname.$node_domain.yml

  FORMULA_PATH=${FORMULA_PATH:-/usr/share/salt-formulas}
  FORMULA_REPOSITORY=${FORMULA_REPOSITORY:-deb [arch=amd64] http://apt-mk.mirantis.com/xenial testing salt}
  FORMULA_GPG=${FORMULA_GPG:-http://apt-mk.mirantis.com/public.gpg}
  FORMULA_SOURCE=${FORMULA_SOURCE:-pkg}

  FORMULA_GIT_BASE=${FORMULA_GIT_BASE:-https://github.com/salt-formulas}
  FORMULA_BRANCH=${FORMULA_BRANCH:-master}

  echo "Configuring salt master formulas ..."
  which wget > /dev/null || (aptget_wrapper update; aptget_wrapper install -y wget)

  if [ "$FORMULA_SOURCE" == "pkg" ]; then
  	echo "${FORMULA_REPOSITORY}" > /etc/apt/sources.list.d/mcp_salt.list
  	wget -O - "${FORMULA_GPG}" | apt-key add - || wait_condition_send "FAILURE" "Failed to add formula key."
  fi

  aptget_wrapper clean
  aptget_wrapper update

  [ ! -d /srv/salt/reclass/classes/service ] && mkdir -p /srv/salt/reclass/classes/service

  declare -a FORMULAS_SALT_MASTER=("linux" "reclass" "salt" "openssh" "ntp" "git" "rsyslog")

  # Source bootstrap_vars for specific cluster if specified.
  for cluster in /srv/salt/reclass/classes/cluster/*/; do
      if [[ -f "$cluster_name/bootstrap_vars" ]]; then
          echo "Sourcing bootstrap_vars for cluster $cluster_name"
          source $cluster_name/bootstrap_vars
      fi
  done

  if [[ -f /srv/salt/reclass/classes/cluster/$cluster_name/.env ]]; then
      source /srv/salt/reclass/classes/cluster/$cluster_name/.env
  fi

  # Patch name of the package for services with _ in name
  FORMULA_PACKAGES=(`echo ${FORMULAS_SALT_MASTER[@]//_/-}`)

  echo -e "\nInstalling all required salt formulas from ${FORMULA_SOUCE}\n"
  if [ "$FORMULA_SOURCE" == "pkg" ]; then
  	aptget_wrapper install -y "${FORMULA_PACKAGES[@]/#/salt-formula-}"
  else
  	for formula in "${FORMULAS_SALT_MASTER[@]}"; do
  		git clone ${FORMULA_GIT_BASE}/salt-formula-${formula}.git ${FORMULA_PATH}/env/_formulas/${formula} -b ${FORMULA_BRANCH}
  		[ ! -L "/usr/share/salt-formulas/env/${formula_service}" ] && \
              		ln -sf ${FORMULA_PATH}/env/_formulas/${formula}/${formula} /usr/share/salt-formulas/env/${formula}
      		[ ! -L "/srv/salt/reclass/classes/service/${formula}" ] && \
  			ln -s ${FORMULA_PATH}/env/_formulas/${formula}/metadata/service /srv/salt/reclass/classes/service/${formula}
  	done
  fi

  for formula_service in "${FORMULAS_SALT_MASTER[@]}"; do
      echo -e "\nLink service metadata for formula ${formula_service} ...\n"
      [ ! -L "/srv/salt/reclass/classes/service/${formula_service}" ] && \
          ln -s ${FORMULA_PATH}/reclass/service/${formula_service} /srv/salt/reclass/classes/service/${formula_service}
  done

  [ ! -d /srv/salt/env ] && mkdir -p /srv/salt/env
  [ ! -L /srv/salt/env/dev ] && ln -s ${FORMULA_PATH}/env /srv/salt/env/dev
  [ ! -L /srv/salt/env/prd ] && ln -s ${FORMULA_PATH}/env /srv/salt/env/prd

  [ ! -d /etc/reclass ] && mkdir /etc/reclass
  cat << 'EOF' > /etc/reclass/reclass-config.yml
storage_type: yaml_fs
pretty_print: True
output: yaml
inventory_base_uri: /srv/salt/reclass
EOF

  echo "Restarting salt-master service ..."
  systemctl restart salt-master || wait_condition_send "FAILURE" "Failed to restart salt-master service."

  echo "Running salt master states ..."
  run_states=("linux,openssh" "reclass" "salt.master.service" "salt")
  for state in "${run_states[@]}"
  do
    salt-call --no-color state.apply "$state" -l info || wait_condition_send "FAILURE" "Salt state $state run failed."
  done

  echo "Syncing modules ..."
  salt-call saltutil.sync_all

  echo "Showing known models ..."
  reclass-salt --top || wait_condition_send "FAILURE" "Reclass-salt command run failed."
fi

sleep 5

echo "Classifying node ..."
os_codename=$(salt-call grains.item oscodename --out key | awk '/oscodename/ {print $2}')
node_network01_ip="$(ip a | awk -v prefix="^    inet $network01_prefix[.]" '$0 ~ prefix {split($2, a, "/"); print a[1]}')"
node_network02_ip="$(ip a | awk -v prefix="^    inet $network02_prefix[.]" '$0 ~ prefix {split($2, a, "/"); print a[1]}')"
node_network03_ip="$(ip a | awk -v prefix="^    inet $network03_prefix[.]" '$0 ~ prefix {split($2, a, "/"); print a[1]}')"
node_network04_ip="$(ip a | awk -v prefix="^    inet $network04_prefix[.]" '$0 ~ prefix {split($2, a, "/"); print a[1]}')"

# find more parameters (every env starting param_)
more_params=$(env | grep "^param_" | sed -e 's/=/":"/g' -e 's/^/"/g' -e 's/$/",/g' | tr "\n" " " | sed 's/, $//g')
if [ "$more_params" != "" ]; then
  echo "Additional params: $more_params"
  more_params=", $more_params"
fi

salt-call event.send "reclass/minion/classify" "{\"node_master_ip\": \"$config_host\", \"node_os\": \"${os_codename}\", \"node_deploy_ip\": \"${node_network01_ip}\", \"node_control_ip\": \"${node_network02_ip}\", \"node_tenant_ip\": \"${node_network03_ip}\", \"node_external_ip\": \"${node_network04_ip}\", \"node_domain\": \"$node_domain\", \"node_cluster\": \"$cluster_name\", \"node_hostname\": \"$node_hostname\"${more_params}}"


# dirty hack to install aio stacks
if [ -f "/srv/salt/reclass/classes/cluster/$cluster_name/install.sh" ]; then
	echo "Starting installation using model script in 30 seconds"
	sleep 30
	/srv/salt/reclass/classes/cluster/$cluster_name/install.sh
fi


wait_condition_send "SUCCESS" "Instance successfuly started."
