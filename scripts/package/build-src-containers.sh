#!/bin/bash

scriptdir=$(realpath $(dirname "$0"))
source "$scriptdir/../../common/common.sh"
source_env

echo "INFO: Build sources containers"
if [[ -z "${REPODIR}" ]] ; then
  echo "ERROR: REPODIR Must be set for build src containers"
  exit 1
fi

buildsh=${REPODIR}/tf-container-builder/containers/build.sh
if ! [[ -x "${buildsh}" ]] ; then
  echo "ERROR: build.sh tool from tf-container-builder is not available in ${REPODIR} or is not executable"
  exit 1
fi

publish_list_file=${PUBLISH_LIST_FILE:-"${DEV_ENV_ROOT}/src_containers_to_publish"}
if ! [[ -f "${publish_list_file}" ]] ; then
  echo "ERROR: targets for build as src containers must be listed at ${publish_list_file}"
  exit 1
fi

dockerfile_template=${DOCKERFILE_TEMPLATE:-"${scriptdir}/Dockerfile.src.tmpl"}
if ! [[ -f "${dockerfile_template}" ]] ; then
  echo "ERROR: Dockerfile template ${dockerfile_template} is not available."
  exit 1
fi

function build_container() {
  local dirname=$1
  local imagename=$2
  # clean .dockerignore before build to get full git repo inside src container
  [ -f ${REPODIR}/${dirname}/.dockerignore ] && rm -f ${REPODIR}/${dirname}/.dockerignore
  # build with prefix 'opensdn-' as a step to rname all
  CONTRAIL_CONTAINER_NAME=${imagename} CUSTOM_CONTAINER_NAME=${imagename} ${buildsh} ${REPODIR}/${dirname}
  rm -f ${REPODIR}/${dirname}/Dockerfile
}

jobs=""
echo "INFO: ===== Start Build Containers for branch=${CONTRAIL_BRANCH,,} at $(date) ====="
while IFS= read -r dirname; do
if ! [[ "$dirname" =~ ^\#.*$ ]] ; then
  if ! [[ "$dirname" =~ ^[\-0-9a-zA-Z\/_.]+$ ]] ; then
    echo "ERROR: Directory name ${dirname} must contain only latin letters, digits or '.', '-', '_' symbols  "
    exit 1
  fi

  if ! [[ -d "${REPODIR}/${dirname}" ]] ; then
    echo "WARNING: not found directory ${REPODIR}/${dirname} mentioned in ${publish_list_file}"
    continue
  fi

  imagename=$dirname
  if [[ "${CONTRAIL_BRANCH,,}" =~ 'master' ]]; then
    imagename="$(echo $dirname | sed 's/^tf/opensdn/')-src"
  fi
  echo "INFO: Pack $dirname sources to container ${imagename} ${buildsh}"
  cp -f ${dockerfile_template} ${REPODIR}/${dirname}/Dockerfile
  build_container ${dirname} ${imagename} &
  jobs+=" $!"
fi
done < ${publish_list_file}

res=0
for i in $jobs ; do
  wait $i || res=1
done

mkdir -p /output/logs/container-builder-src
# do not fail script if logs files are absent
mv ${REPODIR}/tf-container-builder/containers/*.log /output/logs/container-builder-src/ || /bin/true

if [[ $res == 1 ]] ; then
  echo "ERROR: There were some errors when source containers builded."
  exit 1
fi

echo "INFO: All source containers has been successfuly built."
