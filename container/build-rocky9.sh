#!/bin/bash -e

if ! dnf info git-review ; then
  dnf -y install epel-release
fi

if [ -f /etc/dnf.repos.d/pip.conf ] ; then
  mv /etc/dnf.repos.d/pip.conf /etc/
fi

# userspace-rcu is available in crb repo
dnf install -y 'dnf-command(config-manager)'
# it fails in CI - cause we substitute repo files from outside
dnf config-manager --set-enabled crb || /bin/true
dnf repolist

if ! dnf info docker-ce ; then
  echo "INFO: adding docker repo from upstream"
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
fi

# to fix locale warning and to enable following cmd
dnf install -y langpacks-en glibc-all-langpacks dnf-utils

dnf -y install \
  python3 iproute autoconf gdb git git-review jq libtool lsof \
  make cmake libuv-devel vim wget 'docker-ce-3:28.*' rsync procps-ng \
  sudo gcc gcc-c++ net-tools httpd elfutils-libelf-devel \
  python3-virtualenv python3-future python3-tox python3-devel python3-lxml \
  python3-setuptools python3-distro perl-diagnostics tbb openssl openssl-devel \
  libcap-devel libnghttp2-devel boost boost-devel rapidjson-devel \
  doxygen graphviz bison flex bzip2 patch unzip userspace-rcu-devel \
  gperftools-libs gperftools-devel rapidjson-devel hiredis-devel \
  subunit-filters

# build automake 1.16.5 since rocky9 provides only 1.16.2
# required for bind-9.21.3
cd /usr/local/src
wget https://ftp.gnu.org/gnu/automake/automake-1.16.5.tar.gz
tar -xzf automake-1.16.5.tar.gz
cd automake-1.16.5
./configure --prefix=/usr/local
make
make install

# next packages are required for UT
dnf -y install java-1.8.0-openjdk

# this is for net-snmp packages (it is not possible to use BuildRequires in spec
# as it installs openssl-devel-1.1.1 which is incompatible with other Contrail comps 
# (3rd party bind and boost-1.53))
rpm -ivh --nodeps $(repoquery -q --location --latest-limit 1  "mariadb-connector-c-3.*x86_64*" | head -n 1)
rpm -ivh --nodeps $(repoquery -q --location --latest-limit 1  "mariadb-connector-c-devel-3.*x86_64*" | head -n 1)

dnf clean all
rm -rf /var/cache/dnf

pip3 install --retries=10 --timeout 200 --upgrade tox "lxml<5.1" jinja2 wheel pip2pi "chardet<5"

# another strange thing with python3 - some paths are not in sys.path when script is called from spec file
# so add them as a workaround to sys.path explicitely
echo "/usr/local/lib64/python3.9/site-packages" > /usr/lib64/python3.9/site-packages/locallib.pth
echo "/usr/local/lib/python3.9/site-packages" >> /usr/lib64/python3.9/site-packages/locallib.pth

wget -nv ${SITE_MIRROR:-"https://dl.google.com"}/go/go1.23.4.linux-amd64.tar.gz
tar -C /usr/local -xzf go1.23.4.linux-amd64.tar.gz
rm -f go1.23.4.linux-amd64.tar.gz
echo export PATH=$PATH:/usr/local/go/bin >> $HOME/.bashrc

# install, customize and configure compat ssl 1.0.2o
rpm -ivh https://pkgs.sysadmins.ws/el9/base/x86_64/raven-release.el9.noarch.rpm

OPENSSL_ROOT_DIR=/usr/local/ssl
echo export OPENSSL_ROOT_DIR=/usr/local/ssl >> $HOME/.bashrc
echo export LD_LIBRARY_PATH=$CONTRAIL/build/lib:$OPENSSL_ROOT_DIR/lib >> $HOME/.bashrc
echo export LIBRARY_PATH=$LD_LIBRARY_PATH >> $HOME/.bashrc
echo export C_INCLUDE_PATH=$OPENSSL_ROOT_DIR/include:/usr/include/tirpc >> $HOME/.bashrc
echo export CPLUS_INCLUDE_PATH=$C_INCLUDE_PATH >> $HOME/.bashrc
echo export LDFLAGS=\"-L/usr/local/lib -L$OPENSSL_ROOT_DIR/lib\" >> $HOME/.bashrc
echo export PATH=$PATH:$OPENSSL_ROOT_DIR/bin >> $HOME/.bashrc

# pre-load archives for analytics UT
mkdir -p /tmp/cache-systemless_test
wget -nv --tries=3 -c -P /tmp/cache-systemless_test ${SITE_MIRROR:-"https://github.com"}/OpenSDN-io/tf-third-party-cache/raw/master/zookeeper/zookeeper-3.4.5.tar.gz
wget -nv --tries=3 -c -P /tmp/cache-systemless_test ${SITE_MIRROR:-"https://github.com"}/OpenSDN-io/tf-third-party-cache/raw/master/cassandra/apache-cassandra-3.10-bin.tar.gz
wget -nv --tries=3 -c -P /tmp/cache-systemless_test ${SITE_MIRROR:-"https://github.com"}/OpenSDN-io/tf-third-party-cache/raw/master/kafka/kafka_2.11-2.3.1.tgz
wget -nv --tries=3 -c -P /tmp/cache-systemless_test ${SITE_MIRROR:-"https://github.com"}/OpenSDN-io/tf-third-party-cache/raw/master/redis/redis-2.6.13.tar.gz
