#!/bin/bash
set -e
set -x

swapoff --all

#
# Provisioning script for base image of things that build our repositories.
# This pins the versions of all of the external software used in buildslave
# instances, including
# - Docker and dependencies
# - Golang and node
# - AWS and Kubernetes management utilities
# - Etc.
# Some dependencies are updated at the time of running this script, and some
# have fixed version numbers.
#

apt-get update -q -y

# Check that HTTPS transport is available to APT
# (Debian does not enable this by default)
if [ ! -e /usr/lib/apt/methods/https ]; then
    apt-get install -q -y apt-transport-https
fi

apt-get install -q -y software-properties-common wget binutils unzip apt-transport-https ca-certificates curl software-properties-common
apt-get install -q -y g++ make git open-vm-tools apt-transport-https curl arping unzip

# Add the upstream git repo for newer versions
add-apt-repository -y ppa:git-core/ppa

# Upgrade base image even though dist-base does the same thing, but it's
# important to do it again in close timing to doing a bunch more installs.
apt-get update -q -y
apt-get dist-upgrade -q -y
apt-get update -q -y

# Install tools required for Docker
apt-get remove docker-engine || true
apt-get install -q -y \
    aufs-tools \
    iptables \
    ebtables \
    bridge-utils \
    gdisk \
    udev

# awscli
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install --update
rm -f awscliv2.zip

# node & yarn
curl -sL https://deb.nodesource.com/setup_10.x | sudo -E bash -
sudo apt-get install -y nodejs --force-yes
sudo apt-get remove cmdtest
curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
sudo apt-get update
sudo apt-get -o Dpkg::Options::="--force-overwrite" install -y yarn

# Ensure multicast is enabled on eth0
sudo ip link set dev eth0 multicast on

# Wget noisiness
echo "dot_style = giga" >> /etc/wgetrc

# Install Docker
DOCKER_TAR=docker-19.03.8.tgz
wget https://download.docker.com/linux/static/stable/x86_64/${DOCKER_TAR}
tar -C /usr/local/bin -xf ${DOCKER_TAR} --strip-components=1
rm ${DOCKER_TAR}

# Add the user to the 'docker' group, so it can access docker.sock.
# This script is commonly run via sudo, so that would be the SUDO_USER
if [ "$PACKER_BUILDER_TYPE" != "docker" ]; then
    EUSER=$SUDO_USER
    # If this script isn't run via sudo pick whatever user is uid 1000
    if [ -z $EUSER ] || [ "$EUSER" == "root" ]; then
        EUSER=$(awk -F: '$3 == 1000 {print $1; exit}' /etc/passwd)
    fi
    groupadd -g 999 docker || true      # don't error if this exists
    usermod -aG docker $EUSER
fi

# Install Docker startup & configuration scripts
# git clone git@github.com:Badoot/iggybot
cp ./etc-default-docker /etc/default/docker
cp ./etc-init.d-docker /etc/init.d/docker
cp ./etc-init-docker.conf /etc/init/docker.conf

# Docker config
mkdir -p /etc/docker
cat >>/etc/docker/daemon.json <<'EOF'
{
    "graph": "/mnt/docker",
    "bip": "172.17.0.1/16",
    "ipv6": true,
    "fixed-cidr-v6": "2001:db8:1::/64"
}
EOF

# Get and install Packer
PACKERFILENAME=packer
TMPFILE=`mktemp /tmp/${PACKERFILENAME}.XXXXXX` || exit 1
wget -O ${TMPFILE} https://releases.hashicorp.com/packer/1.6.4/packer_1.6.4_linux_amd64.zip
unzip -p ${TMPFILE} > /usr/local/bin/packer
chmod +x /usr/local/bin/packer
rm "${TMPFILE}"


# Install prereqs for protobuf
apt-get install -q -y \
    autoconf \
    automake \
    libtool \
    libltdl-dev \
    unzip

PROTOBUF_VERSION=3.0.2
curl --progress-bar -SLO https://github.com/google/protobuf/archive/v$PROTOBUF_VERSION.tar.gz
tar -xzf "v$PROTOBUF_VERSION.tar.gz"
(cd "protobuf-$PROTOBUF_VERSION" &&
    ./autogen.sh &&
    ./configure --prefix=/usr &&
    make &&
    make install
)
rm -rf "v$PROTOBUF_VERSION.tar.gz" "protobuf-$PROTOBUF_VERSION"

# Install prerequisites for golang
apt-get install -q -y \
    gcc-arm-linux-gnueabihf \
    gcc-aarch64-linux-gnu \
    libc6-dev-armhf-cross \
    libc6-dev-arm64-cross \
    git \
    bzr \
    mercurial \
    subversion

# gcc-multilib is broken and removes other cross compilers
# so install gcc-X-multilib after others and add links
apt-get install -q -y \
    gcc-4.8-multilib
ln -sf /usr/include/x86_64-linux-gnu /usr/local/include/i386-linux-gnu
ln -sf /usr/include/x86_64-linux-gnu /usr/local/include/x86_64-linux-gnux32

# Use our own 'go get' that pins to a specific SHA
cp ./go-install-sha /usr/local/bin/go-install-sha
chmod +x /usr/local/bin/go-install-sha

# Install igneous kernel
BUILDROOT_VERSION=c95f1cac6619756d09e580540ee873bf8bc3358c
KERNEL_VERSION=4.9.220

# Only real systems have a boot disk, this will fail in docker
if [ -e /boot/grub/grub.cfg ]; then
    wget https://igneous-build.s3.amazonaws.com/buildroot/${BUILDROOT_VERSION}/docker_amd64-petra-dev/bzImage -O /boot/vmlinuz-${KERNEL_VERSION}-igneous
    /usr/sbin/update-initramfs -c -k ${KERNEL_VERSION}-igneous

    mkdir -p /etc/default/grub.d
    cat > /etc/default/grub.d/10-kernel.cfg <<EOF
KERNEL_VERSION=${KERNEL_VERSION}
ROOT_UUID=\$(grub-probe --target=fs_uuid /)
GRUB_DEFAULT="gnulinux-advanced-\${ROOT_UUID}>gnulinux-\${KERNEL_VERSION}-igneous-advanced-\${ROOT_UUID}"
EOF
    /usr/sbin/update-grub2
fi

# Go setup
OLD_PATH=$PATH
for GO_VERSION in 1.13.3 1.15.2; do
    GO_DIR=/usr/src/go$GO_VERSION

    # add current go version to PATH, leaking for future use.
    LAST_PATH=$PATH
    export PATH=$GO_DIR/go/bin:$OLD_PATH

    mkdir -p $GO_DIR
    OBJ_NAME=go$GO_VERSION.linux-amd64.tar.gz
    TMPFILE=/tmp/$OBJ_NAME

    wget https://dl.google.com/go/$OBJ_NAME -O $TMPFILE
    tar -C $GO_DIR -xzf $TMPFILE
    rm $TMPFILE

    # apply our patches
    for patch in $(find /opt/iggybot/builder-base/patches/go-$GO_VERSION -name *.patch | sort); do
        patch -p1 -d $GO_DIR/go < $patch
    done

    # cleanup
    unset OBJ_NAME
    unset TMPFILE


    # Newer versions of go require a -i flag to go install
    GOINSTALL="install -i"

    # musl does not have the _chk versions *printf functions found in bits/stdio2.h at -O1 or higher
    export CGO_CFLAGS="-U_FORTIFY_SOURCE"

    # prebuild standard lib
    CGO_ENABLED=1 go ${GOINSTALL} -race std
    CGO_ENABLED=1 go ${GOINSTALL} -tags netgo -installsuffix netgo std
    CGO_ENABLED=1 go ${GOINSTALL} -installsuffix cgo std

    # prebuild standard lib for cross compile
    for platform in linux/386 linux/arm; do
        GOOS=${platform%/*} GOARCH=${platform##*/} CGO_ENABLED=0 \
        GO386=sse2 GOARM=7 go ${GOINSTALL} std
    done

    # explicitly install tools to per-version gopath
    export GOPATH=$GO_DIR/gopath
    mkdir -p $GOPATH
    ln -sf $GOROOT/bin $GOPATH/bin

    # govendor 1.0.9
    go-install-sha github.com/kardianos/govendor f60bcdf2e61a16899c2bd0c793d5914842034455

    # go tools
    go get -d golang.org/x/tools/...
    git -C "$(go env GOPATH)"/src/golang.org/x/tools checkout release-branch.go$(echo $GO_VERSION | cut -f-2 -d.)
    go install -v golang.org/x/tools/cmd/...

    #After go
    export PATH="$PATH:/usr/src/go1.13.3/go/bin"
    export GOPATH="/usr/src/go1.13.3/gopath"
    go get -d "github.com/ttacon/chalk"

    # golint
    go-install-sha golang.org/x/lint/golint d0100b6bd8b389f0385611eb39152c4d7c3a7905

    # protoc-gen-go version numbers are generatorVersion.grpcVersion
    # These values come from the generatedCodeVersion const for each package

    # protoc-gen-go for protobuf 2.2
    go-install-sha github.com/golang/protobuf/protoc-gen-go 5386fff85b00d237cd7d34b2d6ecbb403eb42eb8
    mv $GOPATH/bin/protoc-gen-go $GOPATH/bin/protoc-gen-go-2.2

    # protoc-gen-go 1.3.1
    go-install-sha github.com/golang/protobuf/protoc-gen-go b5d812f8a3706043e23a9cd5babf2e5423744d30

    # msgp 1.1
    go-install-sha github.com/tinylib/msgp af6442a0fcf6e2a1b824f70dd0c734f01e817751

    # Cleanup
    rm -rf $HOME/.cache
    export PATH=$LAST_PATH
    unset LAST_PATH
    unset GO_DIR
    unset GOPATH
    unset CGO_CFLAGS
done

# Clear out go/bin from the path
export PATH=$OLD_PATH
unset OLD_PATH

# Add automake, libtool, lynx (for libnss-mdns)
apt-get install -q -y \
    automake \
    libtool \
    lynx

# Tools used by mesa build
apt-get install -q -y \
    genext2fs \
    mtd-tools \
    sudo \
    tree

# Require clang to build Aws-Cpp-SDK
apt-get install -q -y clang

# Tools used by AWS-resident container services deployments
curl -L "https://storage.googleapis.com/kubernetes-release/release/v1.11.9/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl-1.11
curl -L "https://storage.googleapis.com/kubernetes-release/release/v1.14.5/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl-1.14
curl -L "https://storage.googleapis.com/kubernetes-release/release/v1.18.9/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl-1.18
curl -L "https://storage.googleapis.com/kubernetes-release/release/v1.19.2/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl-1.19
chmod +x /usr/local/bin/kubectl-1.11
chmod +x /usr/local/bin/kubectl-1.14
chmod +x /usr/local/bin/kubectl-1.18
chmod +x /usr/local/bin/kubectl-1.19

ln -sf /usr/local/bin/kubectl-1.11 /usr/local/bin/kubectl

curl -L "https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/v0.5.1/aws-iam-authenticator_0.5.1_linux_amd64" -o /usr/local/bin/aws-iam-authenticator
chmod +x /usr/local/bin/aws-iam-authenticator
ln -sf /usr/local/bin/aws-iam-authenticator /usr/local/bin/heptio-authenticator-aws

# Install pigz parallel gzip utility (for igbundler)
apt-get install -q -y pigz pixz

# Install vmware-vdiskmanager (for vm image building)
curl -L "https://igneous-dev.s3.amazonaws.com/vmware-viskman.tgz" -o /tmp/vmware-vdiskman.tgz
cd /
tar xvf /tmp/vmware-vdiskman.tgz
rm /tmp/vmware-vdiskman.tgz
cd -

# Remove default sysctl tweaks to better match hardware
rm /etc/sysctl.d/*.conf

cat > /etc/sysctl.d/50-more-inotify.conf << 'EOF'
fs.inotify.max_user_watches=1048576
EOF

# grunt needs more files
cat > /etc/security/limits.d/nofile.conf << 'EOF'
* soft nofile 131072
* hard nofile 524288
EOF

# enable limits for su
sed -i='' -e '/pam_limits.so$/s/# //' /etc/pam.d/su

# Tools for buildroot
apt-get install -q -y \
    u-boot-tools \
    gcc-arm-none-eabi \
    gcc-arm-linux-gnueabi \
    device-tree-compiler \
    language-pack-en \
    texinfo \
    qemu-utils \
    libguestfs-tools

update-guestfs-appliance
chmod 644 /boot/vmlinuz-* # supermin perms

# Tools for marvel-cpss
apt-get install -q -y \
    lib32ncurses5 \
    lib32z1

# Tools for qualflash
apt-get install -q -y \
    debootstrap \
    debhelper \
    extlinux \
    genisoimage \
    squashfs-tools \
    syslinux-common

# Tools for dstress
apt-get install -q -y \
    snmp

# Install cmake for heka
apt-get install -q -y cmake

# Install for annotate-output
apt-get install -q -y devscripts

# Install gnuplot for upset test
apt-get install -q -y gnuplot

# Install ecos for newisys-switch
mkdir -p /opt/ecos
cd /opt/ecos
wget ftp://ecos.sourceware.org/pub/ecos/releases/ecos-2.0/ecos-2.0.i386linux.tar.bz2
tar -xf ecos-2.0.i386linux.tar.bz2
wget ftp://ecos.sourceware.org/pub/ecos/gnutools/i386linux/ecoscentric-gnutools-mipsisa32-elf-20081107-sw.i386linux.tar.bz2
tar -xf ecoscentric-gnutools-mipsisa32-elf-20081107-sw.i386linux.tar.bz2
cd -

# newisys-bmc requirements
apt-get install -q -y \
    byacc \
    libncurses5-dev
# perlstrip is useful for smaller rootfs
sudo PERL_MM_USE_DEFAULT=1 perl -MCPAN -e 'install Perl::Strip'

# cri-o (container services) build
apt-get install -q -y \
    btrfs-tools \
    libapparmor-dev \
    libdevmapper-dev \
    libgpgme11-dev \
    libseccomp-dev \
    libglib2.0-dev

# DiskProbe Tools
apt-get install -q -y kpartx

# Base install DCERPC library
apt-get install -q -y flex bison
git clone https://github.com/dcerpc/dcerpc

cat > dcerpc/dcerpc/config.cache <<'EOF'
ac_cv_func_backtrace=${ac_cv_func_backtrace=no}
ac_cv_func_backtrace_symbols=${ac_cv_func_backtrace_symbols=no}
ac_cv_func_backtrace_symbols_fd=${ac_cv_func_backtrace_symbols_fd=no}
ac_cv_func_pthread_atfork=${ac_cv_func_pthread_atfork=no}
ac_cv_func_pthread_yield=${ac_cv_func_pthread_yield=no}
EOF

(cd dcerpc/dcerpc &&
    git checkout 3199d2c0406c4a7eac8e7e6a4c15daeae145386c &&
    autoreconf -fi &&
    CFLAGS=-DAVOID_PTHREAD_ATFORK=1 ./configure \
        --disable-shared --enable-static -C &&
    make &&
    make install
)
rm -rf dcerpc

# tools for things
(
HY_V=hexyl-v0.8.0-x86_64-unknown-linux-musl
wget https://github.com/sharkdp/hexyl/releases/download/v0.8.0/${HY_V}.tar.gz
tar -C /usr/local/bin -xf ${HY_V}.tar.gz --strip-components=1 ${HY_V}/hexyl
rm ${HY_V}.tar.gz

BAT_V=bat-v0.16.0-x86_64-unknown-linux-musl
wget https://github.com/sharkdp/bat/releases/download/v0.16.0/${BAT_V}.tar.gz
tar -C /usr/local/bin -xf ${BAT_V}.tar.gz --strip-components=1 ${BAT_V}/bat
tar -C /usr/local/man/man1 -xf ${BAT_V}.tar.gz --strip-components=1 ${BAT_V}/bat.1
rm ${BAT_V}.tar.gz

HF_V=hyperfine-v1.10.0-x86_64-unknown-linux-musl
wget https://github.com/sharkdp/hyperfine/releases/download/v1.10.0/${HF_V}.tar.gz
tar -C /usr/local/bin -xf ${HF_V}.tar.gz --strip-components=1 ${HF_V}/hyperfine
rm ${HF_V}.tar.gz

FD_V=fd-v8.1.1-x86_64-unknown-linux-musl
wget https://github.com/sharkdp/fd/releases/download/v8.1.1/${FD_V}.tar.gz
tar -C /usr/local/bin -xf ${FD_V}.tar.gz --strip-components=1 ${FD_V}/fd
tar -C /usr/local/man/man1 -xf ${FD_V}.tar.gz --strip-components=1 ${FD_V}/fd.1
rm ${FD_V}.tar.gz

RG_V=ripgrep-12.1.1-x86_64-unknown-linux-musl
wget https://github.com/BurntSushi/ripgrep/releases/download/12.1.1/${RG_V}.tar.gz
tar -C /usr/local/bin -xf ${RG_V}.tar.gz --strip-components=1 ${RG_V}/rg
tar -C /usr/local/man/man1 -xf ${RG_V}.tar.gz --strip-components=2 ${RG_V}/doc/rg.1
rm ${RG_V}.tar.gz

wget https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
mv jq-linux64 /usr/local/bin/jq
chmod +x /usr/local/bin/jq

GOLANGCILINT_V=golangci-lint-1.31.0-linux-amd64
wget https://github.com/golangci/golangci-lint/releases/download/v1.31.0/${GOLANGCILINT_V}.tar.gz
tar -C /usr/local/bin -xf ${GOLANGCILINT_V}.tar.gz --strip-components=1 ${GOLANGCILINT_V}/golangci-lint
chmod +x /usr/local/bin/golangci-lint
rm ${GOLANGCILINT_V}.tar.gz
)

# mv /opt/iggybot/builder-base/hwbridge /etc/init.d/hwbridge
# mv /opt/iggybot/builder-base/hwmacvlan /etc/init.d/hwmacvlan
# chown root.root /etc/init.d/docker /etc/init.d/hwbridge /etc/init.d/hwmacvlan
# chmod 0755 /etc/init.d/docker /etc/init.d/hwbridge /etc/init.d/hwmacvlan
# update-rc.d docker defaults
# update-rc.d hwbridge defaults
# update-rc.d hwmacvlan defaults

# Disable libvirt daemon
echo "manual" > /etc/init/libvirt-bin.override

