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

if [ -z "$aws_instance_id" ]; then
  echo "Running instance cloud-init ..."
  $instance_cloud_init
else
  # AWS
  eval "$instance_cloud_init"
fi

sleep 1

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
