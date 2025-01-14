#!/bin/bash -ex

scriptdir=$(realpath $(dirname "$0"))
source ${scriptdir}/common.sh
source ${scriptdir}/functions.sh

ensure_root

function retry() {
  local i
  for ((i=0; i<5; ++i)) ; do
    if $@ ; then
      break
    fi
    sleep 5
  done
  if [[ $i == 5 ]]; then
    return 1
  fi
}

function install_docker_ubuntu() {
  export DEBIAN_FRONTEND=noninteractive
  which docker && return
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  add-apt-repository -y -u "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  retry apt-get install -y "docker-ce=5:24.0.6-1~ubuntu.20.04~focal"
}

function install_docker_centos() {
  which docker && return
  yum install -y yum-utils device-mapper-persistent-data lvm2
  yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  retry yum install -y docker-ce-cli-20.10.9 docker-ce-20.10.9
}

function install_docker_rocky() {
  which docker && return
  dnf install -y dnf-utils device-mapper-persistent-data lvm2
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  retry dnf install -y docker-ce device-mapper-libs device-mapper-event-libs
  dnf remove -y docker-buildx-plugin
  systemctl start docker
}

function check_docker_value() {
  local name=$1
  local value=$2
  python -c "import json; f=open('/etc/docker/daemon.json'); data=json.load(f); print(data.get('$name'));" 2>/dev/null| grep -qi "$value"
}

function check_insecure_registry() {
  check_docker_value "insecure-registries" "$1"
}

function update_config_docker() {
  local insecure_registries="$1"
  local default_iface_mtu="$2"
  [ ! -e /etc/docker/daemon.json ] && touch /etc/docker/daemon.json
  python <<EOF
import json
data=dict()
try:
  with open("/etc/docker/daemon.json") as f:
    data = json.load(f)
except Exception:
  pass
  
data["default-ulimits"] = {
    "nofile": {
      "Name": "nofile",
      "Soft": 1024,
      "Hard": 1048576
    }
}

if "$UPDATE_INSECURE_REGISTRY" == "true":
  data.setdefault("insecure-registries", list())
  for i in "$insecure_registries".split(','):
    if i not in data["insecure-registries"]:
      data["insecure-registries"].append(i)
data["mtu"] = $default_iface_mtu
data["live-restore"] = True
with open("/etc/docker/daemon.json", "w") as f:
  data = json.dump(data, f, sort_keys=True, indent=4)
EOF
}

function get_docker_mtu() {
  docker network inspect --format='{{index .Options "com.docker.network.driver.mtu"}}' bridge
}

function set_docker_mtu() {
  local default_iface_mtu=$1
  echo "INFO: set docker0 mtu to $default_iface_mtu"
  if [ -x "$(command -v ifconfig)" ]; then
      ifconfig docker0 mtu $default_iface_mtu || true
  else
      ip link set dev docker0 mtu $default_iface_mtu || true
  fi
}

function restart_docker() {
  echo "INFO: restart docker"
  if [[ x"$DISTRO" == x"centos" || x"$DISTRO" == x"rocky" ]] ; then
    systemctl restart docker
  elif [ x"$DISTRO" == x"ubuntu" ]; then
    service docker reload
  else
    echo "ERROR: unknown distro $DISTRO"
    exit 1
  fi
}

echo ""
echo "INFO: [docker install]"
echo "INFO: $DISTRO detected"
if ! which docker >/dev/null 2>&1 ; then
  if [ x"$DISTRO" == x"centos" ]; then
    systemctl stop firewalld || true
    install_docker_centos
    systemctl start docker
  #  grep 'dm.basesize=20G' /etc/sysconfig/docker-storage || sed -i 's/DOCKER_STORAGE_OPTIONS=/DOCKER_STORAGE_OPTIONS=--storage-opt dm.basesize=20G /g' /etc/sysconfig/docker-storage
  #  systemctl restart docker
  elif [ x"$DISTRO" == x"ubuntu" ]; then
    install_docker_ubuntu
  elif [ x"$DISTRO" == x"rocky" ]; then
    systemctl stop firewalld || true
    install_docker_rocky
  fi
else
  echo "INFO: docker installed: $(docker --version)"
  version=$(docker version --format '{{.Client.Version}}' 2>/dev/null | head -1 | cut -d '.' -f 1)
  if (( version < 16)); then
    echo "ERROR: docker is too old. please remove it. tf-dev-env will install correct version."
    exit 1
  fi
fi


echo
echo "INFO: [docker config]"
default_iface=`ip route get 1 | grep -o "dev.*" | awk '{print $2}'`

CONTRAIL_SKIP_INSECURE_REGISTRY=${CONTRAIL_SKIP_INSECURE_REGISTRY:-0}
insecure_registries=${INSECURE_REGISTRIES:-}
registry_ip=${REGISTRY_IP}
UPDATE_INSECURE_REGISTRY=false
if [ "$CONTRAIL_SKIP_INSECURE_REGISTRY" != 0 ]; then
  echo "INFO: Docker config - setting insecure registry skipped"
else
  if [ -z $registry_ip ]; then
    # use default ip as registry ip if it's not passed to the script
    registry_ip=`ip addr show dev $default_iface | awk '/inet /{print $2}' | cut -f '1' -d '/'`
  fi
  if ! check_insecure_registry "${registry_ip}:${REGISTRY_PORT}" ; then
    if [ -n "$insecure_registries" ] ; then
      insecure_registries+=","
    fi
    insecure_registries+="${registry_ip}:${REGISTRY_PORT}"
  fi
fi
if [ -n "$insecure_registries" ] ; then
  UPDATE_INSECURE_REGISTRY=true
fi

default_iface_mtu=`ip link show $default_iface | grep -o "mtu.*" | awk '{print $2}'`

docker_reload=0
if $UPDATE_INSECURE_REGISTRY || ! check_docker_value mtu "$default_iface_mtu" || ! check_docker_value "live-restore" "true" ; then
  update_config_docker "$insecure_registries" "$default_iface_mtu"
  docker_reload=1
else
  echo "INFO: no config changes required"
fi

runtime_docker_mtu=$(get_docker_mtu)
if [[ "$default_iface_mtu" != "$runtime_docker_mtu" || "$docker_reload" == '1' ]]; then
  set_docker_mtu $default_iface_mtu
  restart_docker
else
  echo "INFO: no docker service restart required"
fi

echo "REGISTRY_IP: $registry_ip"
