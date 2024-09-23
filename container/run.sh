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

declare -a all_stages=(fetch configure compile package test freeze doxygen)
declare -a default_stages=(fetch configure)
declare -a build_stages=(fetch configure compile package)

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
        echo $CONTRAIL_CONTAINER_TAG | sed 's/[_-]/./g' > $vfile
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
    if [[ ! "${CONTRAIL_BRANCH^^}" =~ 'R1912' && ! "${CONTRAIL_BRANCH^^}" =~ 'R2011' && ! "${CONTRAIL_BRANCH^^}" =~ 'R21.4' ]]; then
        # install all python tools for build with python3 only
        # after full switch of build to python3 - drop these tools from reqs in spec files
        python3 -m pip install scons future lxml "Sphinx<7.3.0" requests setuptools "pyyaml<6"
    fi

    local targets="$@"
    [ -n "$targets" ] || targets="setup tpp dep"

    # frozen may have contrail repo set (e.g. if tpp changed)
    # it is needed to have up rpm repo any stage that operates with yum
    make setup-httpd
    if [[ "$targets" =~ 'setup' ]] ; then
        echo "INFO: make setup  $(date)"
        make setup
    fi

    if [[ "$targets" =~ 'tpp' ]] ; then
        if [[ "$targets" == 'tpp' ]] ; then 
            export BUILD_TPP_FORCE='true'
        fi
        echo "INFO: make fetch_packages $(date)"
        make fetch_packages
    fi

    if [[ "$targets" =~ 'dep' ]] ; then
        echo "INFO: make dep $(date)"
        make dep
    fi

    # disable byte compiling
    if [[ ! -f /usr/lib/rpm/brp-python-bytecompile.org  ]] ; then
        echo "INFO: disable byte compiling for python"
        mv /usr/lib/rpm/brp-python-bytecompile /usr/lib/rpm/brp-python-bytecompile.org
        cat <<EOF | tee /usr/lib/rpm/brp-python-bytecompile
#!/bin/bash
# disabled byte compiling
exit 0
EOF
        chmod +x /usr/lib/rpm/brp-python-bytecompile
    fi
}

function compile() {
    local targets="$@"
    [ -n "$targets" ] || targets="tpp rpm"

    echo "INFO: compile: $targets"
    echo "INFO: Check variables used by makefile"
    uname -a
    make info

    # frozen may have contrail repo set (e.g. if tpp changed)
    # it is needed to have up rpm repo any stage that operates with yum
    make setup-httpd

    # Remove information about FROZEN_TAG so that package stage doesn't try to use ready containers.
    export FROZEN_TAG=""
    save_tf_devenv_profile

    echo "INFO: create rpm repo $(date)"
    # remove all built rpm-s if stage is compile - otherwise package may take newer files from frozen container
    rm -rf $WORK_DIR/RPMS/*

    make create-repo
    if [[ "$targets" =~ 'tpp' ]] ; then
        if [[ "$targets" == 'tpp' ]] ; then 
            export BUILD_TPP_FORCE='true'
        fi
        echo "INFO: make tpp $(date)"
        make build-tpp
        echo "INFO: update rpm repo $(date)"
        make update-repo
        echo "INFO: package tpp $(date)"
        # TODO: for now it does packaging for all rpms found in repo,
        # at this moment tpp packages are built only if there are changes there
        # from gerrit. So, for now it relies on tha fact that it is first step of RPMs.
        make package-tpp
    fi
    if [[ "$targets" =~ 'rpm' ]] ; then
        echo "INFO: CONTRAIL_BRANCH=${CONTRAIL_BRANCH^^}"
        if [[ ! "${CONTRAIL_BRANCH^^}" =~ 'R1912' ]] && [[ ! "${CONTRAIL_BRANCH^^}" =~ 'R2011' ]]; then
            if [ -e /opt/rh/devtoolset-7/enable ]; then
                echo "INFO: enable /opt/rh/devtoolset-7/enable"
                source /opt/rh/devtoolset-7/enable
            fi
        fi
        echo "INFO: make rpm  $(date)"
        make rpm
        echo "INFO: update rpm repo $(date)"
        make update-repo
    fi
}

function test() {
    echo "INFO: Starting unit tests"
    uname -a
    TEST_PACKAGE=$1 make test
}

function package() {
    #Package everything
    echo "INFO: Check variables used by makefile"
    uname -a
    make info

    set -x

    # frozen may have contrail repo set (e.g. if tpp changed)
    # it is needed to have up rpm repo any stage that operates with yum
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
        if [[ ! -z $changed_operator_projects ]] ; then
            make_containers="${make_containers} operator-containers"
            echo "INFO: operator containers has changed"
        fi
        if [[ ! -z $changed_tests_projects ]] ; then
            make_containers="${make_containers} test-containers"
            echo "INFO: test containers has changed"
        fi
    else
        make_containers="containers src-containers test-containers operator-containers"
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
