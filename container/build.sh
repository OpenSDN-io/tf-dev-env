#!/bin/bash -e

scriptdir=$(realpath $(dirname "$0"))
source ${scriptdir}/../common/common.sh

function mysudo() {
    if [[ $DISTRO == "macosx" ]]; then
        "$@"
    else
        sudo $@
    fi
}

LINUX_DISTR=${LINUX_DISTR:-'centos'}
LINUX_DISTR_VER=${LINUX_DISTR_VER:-7}

CONTRAIL_KEEP_LOG_FILES=${CONTRAIL_KEEP_LOG_FILES:-'false'}

mkdir -p ${WORKSPACE}/output/logs
logfile="${WORKSPACE}/output/logs/build-tf-dev-env.log"
echo "Building tf-dev-env image: ${DEVENV_IMAGE}" | tee $logfile

build_opts="--build-arg LC_ALL=en_US.UTF-8 --build-arg LANG=en_US.UTF-8 --build-arg LANGUAGE=en_US.UTF-8"
build_opts+=" --build-arg LINUX_DISTR=$LINUX_DISTR --build-arg LINUX_DISTR_VER=$LINUX_DISTR_VER"
build_opts+=" --build-arg SITE_MIRROR=${SITE_MIRROR:+${SITE_MIRROR}/external-web-cache}"
if [[ "$LINUX_DISTR" =~ 'centos' ]] ; then
    docker_file="Dockerfile.centos"
elif [[ "$LINUX_DISTR" =~ 'rocky' ]] ; then
    docker_file="Dockerfile.rocky"
else
    echo "ERROR: unsupported linux distro: $LINUX_DISTR"
    exit 1
fi

docker_ver=$(mysudo docker -v | awk -F' ' '{print $3}' | sed 's/,//g')
echo "INFO: Docker version: $docker_ver"

if [[ "$docker_ver" < '17.06' ]] ; then
    echo "ERROR: unsupported docker version $docker_ver"
    exit 1
fi

#Configuring tpc.repo
sed -i "s|___SITE_MIRROR___|${SITE_MIRROR:-"http://nexus.opensdn.io/repository"}|" tpc.repo

echo "INFO: DISTRO=$DISTRO DISTRO_VER=$DISTRO_VER DISTRO_VER_MAJOR=$DISTRO_VER_MAJOR"
build_opts+=" --network host --no-cache --tag ${DEVENV_IMAGE} --tag ${CONTAINER_REGISTRY}/${DEVENV_IMAGE} -f $docker_file ."

if [[ $DISTRO != 'macosx' ]] ; then
    CONTRAIL_KEEP_LOG_FILES=${CONTRAIL_KEEP_LOG_FILES,,}
fi
if [[ "${CONTRAIL_KEEP_LOG_FILES}" != 'true' ]] ; then
   echo "INFO: build cmd: docker build $build_opts"
   mysudo docker build $build_opts 2>&1 | tee -a $logfile
   result=${PIPESTATUS[0]}
   if [ $result -eq 0 ]; then
      rm -f $logfile
   fi
else
   # skip output into terminal
   echo "INFO: build cmd: docker build $build_opts"
   mysudo docker build $build_opts >> $logfile 2>&1
   result=${PIPESTATUS[0]}
fi

exit $result
