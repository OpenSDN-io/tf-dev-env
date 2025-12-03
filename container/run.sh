#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/common.sh"
source "$my_dir/../common/functions.sh"
source "$my_dir/../common/tf_functions.sh"

stage="$1"
target="$2"

echo "INFO: run stage $stage with target $target"

set -eo pipefail

load_tf_devenv_profile
source_env
prepare_infra
cd $DEV_ENV_ROOT

[ -n "$DEBUG" ] && set -x

declare -a all_stages=(fetch configure compile package test freeze doxygen publish)
declare -a default_stages=(fetch configure)
declare -a build_stages=(fetch configure compile package publish)

function fetch() {
    verify_tag=$(get_current_container_tag)
    while true ; do
        # Sync sources
        echo "INFO: make sync  $(date)"
        make sync
        current_tag=$(get_current_container_tag)
        if [[ $verify_tag == $current_tag ]] ; then
            export FROZEN_TAG=$current_tag
            save_tf_devenv_profile
            break
        fi
        # If tag's changed during our fetch we'll cleanup sources and retry fetching
        echo "WARNING: tag was changed ($verify_tag -> $current_tag). Run sync again..."
        verify_tag=$current_tag
    done

    # paths must be fixed inside tf-dev-sandbox container
    for vfile in $(find .. -name version.info); do
        echo "INFO: patching file $vfile"
        echo "v0+$CONTRAIL_CONTAINER_TAG" | sed 's/[_-]/./g' > $vfile
    done

    # Invalidate stages after new fetch. For fast build and patchest invalidate only if needed.
    if [[ $BUILD_MODE == "fast" ]] ; then
        echo "INFO: Checking patches for fast build mode"
        if patches_exist ; then
            echo "INFO: patches encountered" $changed_projects
            if [[ -n $changed_product_projects ]] ; then
                echo "INFO: Contrail core is changed, cleaning all stages"
                cleanup compile
                # vrouter dpdk project uses makefile and relies on date of its artifacts to be fresher than sources
                # which after resyncing here isn't true, so we'll refresh it if it's unchanged to skip rebuilding
                if ! [[ ${changed_product_project[@]} =~ "tf-dpdk" ]] ; then
                    find $WORK_DIR/build/production/vrouter/dpdk/x86_64-native-linuxapp-gcc/build -type f -exec touch {} + || /bin/true
                fi
            fi
        else
            echo "INFO: No patches encountered"
        fi
        # Cleaning packages stage because we need to fetch ready containers if they're not to be built
        cleanup package
    else
        cleanup
    fi
}

function configure() {
    # targets can use yum and will block each other. don't run them in parallel
    echo "INFO: CONTRAIL_BRANCH=${CONTRAIL_BRANCH^^}"
    echo "INFO: make fetch_packages $(date)"
    make fetch_packages
    echo "INFO: make dep $(date)"
    make dep
}

function compile() {
    echo "INFO: CONTRAIL_BRANCH=${CONTRAIL_BRANCH^^}"
    echo "INFO: compile: $targets  $(date)"

    # Remove information about FROZEN_TAG so that package stage doesn't try to use ready containers.
    export FROZEN_TAG=""
    save_tf_devenv_profile

    echo "INFO: CONTRAIL_BRANCH=${CONTRAIL_BRANCH^^}"
    if [ -e /opt/rh/devtoolset-7/enable ]; then
        echo "INFO: enable /opt/rh/devtoolset-7/enable"
        source /opt/rh/devtoolset-7/enable
    fi
    echo "INFO: make compile $(date)"
    make compile
    dir2pi /pip/
    docker commit $DEVENV_CONTAINER_NAME ${DEVENV_IMAGE_NAME}:compile
    docker images
}

function test() {
    echo "INFO: Starting unit tests  $(date)"
    TEST_PACKAGE=$1 make test
}

function package() {
    echo "INFO: Start packaging  $(date)"

    # set up httpd repo with pip packages to able to use them in images build
    make setup-httpd

    # Check if we're packaging only a single target
    if [[ -n "$target" ]] ; then
        echo "INFO: packaging only ${target}"
        make $target
        return $?
    fi

    local make_containers=""
    # Check if we're run by Jenkins and have an automated patchset
    if [[ $BUILD_MODE == "fast" ]] && [[ -n $FROZEN_TAG ]] && patches_exist ; then
        echo "INFO: checking containers changes for fast build"
        if [[ ! -z $changed_containers_projects ]] ; then
            echo "INFO: core containers has changed"
            make_containers="containers src-containers"
        elif [[ ! -z $changed_deployers_projects ]] ; then
            echo "INFO: deployers containers has changed"
            make_containers="src-containers"
        fi
        if [[ ! -z $changed_tests_projects ]] ; then
            make_containers="${make_containers} test-containers"
            echo "INFO: test containers has changed"
        fi
    else
        make_containers="containers src-containers test-containers"
    fi

    # build containers
    if [[ -n $make_containers ]] ; then
        echo "INFO: make $make_containers $(date)"
        if ! make -j 8 $make_containers ; then
            echo "INFO: make containers failed $(date)"
            exit 1
        fi
    fi

    local res=0
    # Pull containers which build skipped
    for container in ${unchanged_containers[@]}; do
        # TODO: CONTRAIL_REGISTRY here should actually be CONTAINER_REGISTRY but the latter is not passed inside the container now
        echo "INFO: fetching unchanged $container and pushing it as $CONTRAIL_REGISTRY/$container:$CONTRAIL_CONTAINER_TAG"
        if [[ $(docker pull "$FROZEN_REGISTRY/$container:$FROZEN_TAG") ]] ; then
            docker tag "$FROZEN_REGISTRY/$container:$FROZEN_TAG" "$CONTRAIL_REGISTRY/$container:$CONTRAIL_CONTAINER_TAG" || res=1
            docker push "$CONTRAIL_REGISTRY/$container:$CONTRAIL_CONTAINER_TAG" || res=1
        else
            res=1
            echo "INFO: not found frozen $container with tag $FROZEN_TAG"
        fi
    done
    if [[ "$res" != '0' ]]; then
        echo "ERROR: failed to re-tag some unchanged containers"
        exit 1
    fi

    echo "INFO: Build of containers with deployers has finished successfully"
}

function freeze() {
    # Prepare this container for pushing
    # Unlink all symlinks in contrail folder
    find $HOME/contrail -maxdepth 1 -type l | xargs -L 1 unlink
    # scons rewrites .sconsign.dblite so as double protection we'll save it if it's still in contrail
    if [[ -e "${HOME}/contrail/.sconsign.dblite" ]]; then
        rm -f ${HOME}/work/.sconsign.dblite
        mv ${HOME}/contrail/.sconsign.dblite ${HOME}/work/
    fi
    # Check if sources (contrail folder) are mounted from outside and remove if not
    if ! mount | grep "contrail type" ; then
        rm -rf $HOME/contrail || /bin/true
    fi
}

function doxygen() {
    # Builds doxygen documentation for the project
    echo "INFO: Doxygen stage"

    export DOXYGEN_SRC="/root/contrail/"            # Used by Doxyfile
    export DOXYFILE="/root/tf-dev-env/Doxyfile"     # Used by Makefile
    export DOXYGEN_RES="$DOXYGEN_SRC/doxygen-docs/" # Where to store results
    if [ -f "$DOXYFILE" ] ; then
        echo "INFO: Doxygen stage: Cleaning old documentation"
        rm -rf "$DOXYGEN_RES"
        mkdir -p "$DOXYGEN_RES"

        echo "INFO: Doxygen stage: running the doxygen translator"
        make doxygen
    else
        echo "INFO: Doxygen stage: Cannot find the Doxygen file ($DOXYFILE)"
    fi
}

function publish() {
    echo "INFO: Start publish $(date)"

    if [[ -z "$OPENSDN_REGISTRY_PUSH" ]]; then
        echo "INFO: OPENSDN_REGISTRY_PUSH is not set. Skipping publish stage."
        return 0
    fi

    if [[ -n "$OPENSDN_REGISTRY_USERNAME" ]] && [[ -n "$OPENSDN_REGISTRY_PASSWORD" ]]; then
        echo "INFO: Logging in to registry $OPENSDN_REGISTRY_PUSH"
        echo "$OPENSDN_REGISTRY_PASSWORD" | docker login "$OPENSDN_REGISTRY_PUSH" -u "$OPENSDN_REGISTRY_USERNAME" --password-stdin
    fi

    echo "INFO: Pushing images to $OPENSDN_REGISTRY_PUSH"

    # Find all images with the current CONTRAIL_CONTAINER_TAG and CONTRAIL_REGISTRY prefix
    local images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "^${CONTRAIL_REGISTRY}/.*:${CONTRAIL_CONTAINER_TAG}$")

    if [[ -z "$images" ]]; then
        echo "WARNING: No images found to push matching ${CONTRAIL_REGISTRY}/*:${CONTRAIL_CONTAINER_TAG}"
        return 0
    fi

    for img in $images; do
        # Extract container name (remove registry prefix and tag)
        # img format: registry/container_name:tag
        local repo_tag=${img#${CONTRAIL_REGISTRY}/} # container_name:tag
        local container_name=${repo_tag%:${CONTRAIL_CONTAINER_TAG}} # container_name

        local target_image="${OPENSDN_REGISTRY_PUSH}/${container_name}:${CONTRAIL_CONTAINER_TAG}"

        echo "INFO: Tagging $img as $target_image"
        docker tag "$img" "$target_image"

        echo "INFO: Pushing $target_image"
        if ! docker push "$target_image"; then
            echo "ERROR: Failed to push $target_image"
            return 1
        fi
    done

    echo "INFO: Publish finished successfully $(date)"
}


function run_stage() {
    if ! finished_stage $1 ; then
        $1 $2
        touch $STAGES_DIR/$1 || true
    else
        echo "INFO: Skipping stage $stage in $BUILD_MODE mode"
    fi
}

function finished_stage() {
    [ -e $STAGES_DIR/$1 ]
}

function cleanup() {
    local stage=${1:-'*'}
    rm -f $STAGES_DIR/$stage
}

function enabled() {
    [[ "$1" =~ "$2" ]]
}

# select default stages
if [[ -z "$stage" ]] ; then
    for dstage in ${default_stages[@]} ; do
        run_stage $dstage
    done
elif [[ "$stage" =~ 'build' ]] ; then
    # run default stages for 'build' option
    for bstage in ${build_stages[@]} ; do
        run_stage $bstage $target
    done
else
    # run selected stage unless we're in fast build mode and the stage is finished. TODO: remove skipping package when frozen containers are available.
    if [[ $BUILD_MODE == "full" ]] || [[ $stage == "fetch" ]] || [[ $stage == "configure" ]] || [[ $stage == "package" ]] ; then
        cleanup $stage
    fi
    run_stage $stage $target
fi

echo "INFO: make successful  $(date)"
