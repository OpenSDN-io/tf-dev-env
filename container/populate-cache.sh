#!/bin/bash -e

if ! which wget; then
   echo "ERROR: wget is not found. please install it. exit"
   exit 1
fi

CACHE_DIR=${CACHE_DIR:-'/tmp/cache'}

mkdir -p $CACHE_DIR || true
pushd $CACHE_DIR

wget -nv -t3 -P go https://dl.google.com/go/go1.23.4.linux-amd64.tar.gz

# commented because URL-s are unavailable
#wget -nv -t3 -P el8/extras/x86_64 https://pkgs.dyn.su/el8/extras/x86_64/compat-openssl10-devel-1.0.2o-3.el8.x86_64.rpm
#wget -nv -t3 -P pkgs/packages/compat-openssl10/1.0.2o/3.el8/x86_64 https://koji.mbox.centos.org/pkgs/packages/compat-openssl10/1.0.2o/3.el8/x86_64/compat-openssl10-debugsource-1.0.2o-3.el8.x86_64.rpm

#Upgrading git in centos7
#default git 1.18 causes fail (HTTP 402) in fetch-sources job when it's working with gitlab
wget -nv -t3 -P rhel/7/os/x86_64 https://packages.endpointdev.com/rhel/7/os/x86_64/git-core-2.37.1-1.ep7.x86_64.rpm
wget -nv -t3 -P rhel/7/os/x86_64 https://packages.endpointdev.com/rhel/7/os/x86_64/git-2.37.1-1.ep7.x86_64.rpm
wget -nv -t3 -P rhel/7/os/x86_64 https://packages.endpointdev.com/rhel/7/os/x86_64/git-core-doc-2.37.1-1.ep7.noarch.rpm
wget -nv -t3 -P rhel/7/os/x86_64 https://packages.endpointdev.com/rhel/7/os/x86_64/perl-Git-2.37.1-1.ep7.noarch.rpm

wget -nv -t3 -P OpenSDN-io/tf-third-party-cache/raw/master/zookeeper https://github.com/OpenSDN-io/tf-third-party-cache/raw/master/zookeeper/zookeeper-3.4.5.tar.gz
wget -nv -t3 -P OpenSDN-io/tf-third-party-cache/raw/master/cassandra https://github.com/OpenSDN-io/tf-third-party-cache/raw/master/cassandra/apache-cassandra-3.10-bin.tar.gz
wget -nv -t3 -P OpenSDN-io/tf-third-party-cache/raw/master/kafka     https://github.com/OpenSDN-io/tf-third-party-cache/raw/master/kafka/kafka_2.11-2.3.1.tgz
wget -nv -t3 -P OpenSDN-io/tf-third-party-cache/raw/master/redis     https://github.com/OpenSDN-io/tf-third-party-cache/raw/master/redis/redis-2.6.13.tar.gz

popd
