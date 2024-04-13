#!/bin/bash -e

if ! dnf info git-review ; then
  dnf -y install epel-release
fi

#if [ -f /etc/dnf.repos.d/pip.conf ] ; then
#  mv /etc/dnf.repos.d/pip.conf /etc/
#fi

# to fix locale warning and to enable following cmd
dnf install -y langpacks-en glibc-all-langpacks dnf-utils

dnf --enable config-manager devel crb

dnf -y install \
  python3 iproute autoconf automake createrepo gdb git git-review jq libtool \
  make cmake libuv-devel rpm-build vim wget \
  rpmdevtools sudo gcc-c++ net-tools httpd elfutils-libelf-devel \
  python3-virtualenv python3-future python3-tox python3-devel python3-lxml \
  doxygen graphviz

# next packages are required for UT
dnf -y install java-1.8.0-openjdk

# this is for net-snmp packages (it is not possible to use BuildRequires in spec
# as it installs openssl-devel-1.1.1 which is incompatible with other Contrail comps 
# (3rd party bind and boost-1.53))
rpm -ivh --nodeps $(repoquery -q --location --latest-limit 1  "mariadb-connector-c-3.*x86_64*"  | head -n 1)
rpm -ivh --nodeps $(repoquery -q --location --latest-limit 1  "mariadb-connector-c-devel-3.*x86_64*"  | head -n 1)

dnf clean all
rm -rf /var/cache/dnf

pip3 install --retries=10 --timeout 200 --upgrade tox setuptools "lxml<5.1" jinja2

wget -nv ${SITE_MIRROR:-"https://dl.google.com"}/go/go1.14.2.linux-amd64.tar.gz
tar -C /usr/local -xzf go1.14.2.linux-amd64.tar.gz
rm -f go1.14.2.linux-amd64.tar.gz
echo export PATH=$PATH:/usr/local/go/bin >> $HOME/.bashrc
wget -nv ${SITE_MIRROR:-"https://github.com"}/operator-framework/operator-sdk/releases/download/v0.17.2/operator-sdk-v0.17.2-x86_64-linux-gnu -O /usr/local/bin/operator-sdk-v0.17
wget -nv ${SITE_MIRROR:-"https://github.com"}/operator-framework/operator-sdk/releases/download/v0.18.2/operator-sdk-v0.18.2-x86_64-linux-gnu -O /usr/local/bin/operator-sdk-v0.18
ln -s /usr/local/bin/operator-sdk-v0.18 /usr/local/bin/operator-sdk
chmod u+x /usr/local/bin/operator-sdk-v0.17 /usr/local/bin/operator-sdk-v0.18 /usr/local/bin/operator-sdk

# install, customize and configure compat ssl 1.0.2o
rpm -ivh https://pkgs.dyn.su/el9/base/x86_64/raven-release.el9.noarch.rpm
dnf install -y compat-openssl10 compat-openssl10-devel
# ?? ${SITE_MIRROR:-"https://koji.mbox.centos.org"}/pkgs/packages/compat-openssl10/1.0.2o/3.el8/x86_64/compat-openssl10-debugsource-1.0.2o-3.el8.x86_64.rpm

OPENSSL_ROOT_DIR=/usr/local/ssl
echo export OPENSSL_ROOT_DIR=/usr/local/ssl >> $HOME/.bashrc
echo export LD_LIBRARY_PATH=$CONTRAIL/build/lib:$OPENSSL_ROOT_DIR/lib >> $HOME/.bashrc
echo export LIBRARY_PATH=$LD_LIBRARY_PATH >> $HOME/.bashrc
echo export C_INCLUDE_PATH=$OPENSSL_ROOT_DIR/include:/usr/include/tirpc >> $HOME/.bashrc
echo export CPLUS_INCLUDE_PATH=$C_INCLUDE_PATH >> $HOME/.bashrc
echo export LDFLAGS=\"-L/usr/local/lib -L$OPENSSL_ROOT_DIR/lib\" >> $HOME/.bashrc
echo export PATH=$PATH:$OPENSSL_ROOT_DIR/bin >> $HOME/.bashrc

mkdir -p $OPENSSL_ROOT_DIR/lib
ln -s /usr/src/debug/compat-openssl10-1.0.2o-3.el8.x86_64/include $OPENSSL_ROOT_DIR/include
ln -s /usr/lib64/libcrypto.so.10 $OPENSSL_ROOT_DIR/lib/libcrypto.so
ln -s /usr/lib64/libssl.so.10 $OPENSSL_ROOT_DIR/lib/libssl.so
