# Required variables:
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
			ln -s ${FORMULA_PATH}/env/_formulas/${formula}/metadata /srv/salt/reclass/classes/service/${formula}
	done
fi

for formula_service in "${FORMULAS_SALT_MASTER[@]}"; do
    echo -e "\nLink service metadata for formula ${formula_service} ...\n"
    [ ! -L "/srv/salt/reclass/classes/service/${formula_service}" ] && \
        ln -s ${FORMULA_PATH}/reclass/service/${formula_service} /srv/salt/reclass/classes/service/${formula_service}
done

[ ! -d /srv/salt/env ] && mkdir -p /srv/salt/env
[ ! -L /srv/salt/env/dev ] && ln -s ${FORMULA_PATH}/env /srv/salt/env/dev

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

