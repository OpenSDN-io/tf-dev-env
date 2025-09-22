TF_DE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
TF_DE_TOP := $(abspath $(TF_DE_DIR)/../)/
SHELL=/bin/bash -o pipefail

REPODIR=$(TF_DE_TOP)contrail
CONTAINER_BUILDER_DIR=$(REPODIR)/tf-container-builder
CONTRAIL_TEST_DIR=$(REPODIR)/third_party/contrail-test
export REPODIR
export CONTRAIL_TEST_DIR
export CONTAINER_BUILDER_DIR

all: compile containers

dep:
	@$(REPODIR)/tools/build/dep.sh

# TODO: pass /pip/ dir to compile.sh as a place to store built pip packages
compile:
	@$(REPODIR)/tools/build/compile.sh

fetch_packages:
	@$(TF_DE_DIR)scripts/fetch-packages.sh

sync:
	@$(TF_DE_DIR)scripts/sync-sources.sh

##############################################################################
# RPM repo targets for TPP only
create-repo:
	@mkdir -p $(REPODIR)/RPMS
	@createrepo --update $(REPODIR)/RPMS/
	@dir2pi /pip/
	@echo "INFO: clean all for contrail repo after udpate"
	@yum clean all --disablerepo=* --enablerepo=contrail || true

update-repo: create-repo

clean-repo:
	@test -d $(REPODIR)/RPMS/repodata && rm -rf $(REPODIR)/RPMS/repodata || true

setup-httpd:
	@$(TF_DE_DIR)scripts/setup-httpd.sh

##############################################################################
# Contrail third party packaged
build-tpp:
	@$(TF_DE_DIR)scripts/build-tpp.sh

package-tpp:
	@$(TF_DE_DIR)scripts/package-tpp.sh

##############################################################################
# Container deployer-src targets
src-containers:
	@$(TF_DE_DIR)scripts/package/build-src-containers.sh |& sed "s/^/src-containers: /"

##############################################################################
# Container builder targets
prepare-containers:
	@$(TF_DE_DIR)scripts/package/prepare-containers.sh |& sed "s/^/containers: /"

list-containers:
	@$(TF_DE_DIR)scripts/package/list-containers.sh $(CONTAINER_BUILDER_DIR) container

container-%:
	@$(TF_DE_DIR)scripts/package/build-containers.sh $(CONTAINER_BUILDER_DIR) container $(patsubst container-%,%,$(subst _,/,$(@))) | sed "s/^/$(@): /"

containers-only:
	@$(TF_DE_DIR)scripts/package/build-containers.sh $(CONTAINER_BUILDER_DIR) container |& sed "s/^/containers: /"

containers: prepare-containers containers-only

##############################################################################
# Test container targets
test-containers:
	@$(TF_DE_DIR)scripts/package/build-test-containers.sh |& sed "s/^/test-containers: /"

##############################################################################
# Unit Test targets
test:
	@$(TF_DE_DIR)scripts/run-tests.sh $(TEST_PACKAGE)

##############################################################################
# Prepare Doxygen documentation
doxygen:
	echo $(DOXYFILE)
	doxygen $(DOXYFILE)

##############################################################################
# Other clean targets
clean-rpm:
	@test -d $(REPODIR)/RPMS && rm -rf $(REPODIR)/RPMS/* || true

clean: clean-deployers clean-containers clean-repo
	@$(REPODIR)/tools/build/clean.sh

dbg:
	@echo $(TF_DE_TOP)
	@echo $(TF_DE_DIR)

.PHONY: clean-deployers clean-containers clean-repo setup build containers deployers createrepo all
