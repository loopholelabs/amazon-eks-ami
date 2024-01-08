#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit
IFS=$'\n\t'

################################################################################
### Validate Required Arguments ################################################
################################################################################
validate_env_set() {
  (
    set +o nounset

    if [ -z "${!1}" ]; then
      echo "Packer variable '$1' was not set. Aborting"
      exit 1
    fi
  )
}

validate_env_set WORKING_DIR
validate_env_set USER
validate_env_set GITHUB_ACCESS_TOKEN

################################################################################
### Machine Architecture #######################################################
################################################################################

MACHINE=$(uname -m)
if [ "$MACHINE" == "x86_64" ]; then
  ARCH="amd64"
elif [ "$MACHINE" == "aarch64" ]; then
  ARCH="arm64"
else
  echo "Unknown machine architecture '$MACHINE'" >&2
  exit 1
fi

################################################################################
### Packages ###################################################################
################################################################################

sudo yum install -y \
  git \
  make \
  automake \
  docker \
  wget \
  gcc \
  qemu \
  bison \
  flex \
  bc

################################################################################
### Install Golang #############################################################
################################################################################

wget "https://go.dev/dl/go1.21.5.linux-$ARCH.tar.gz" -O $WORKING_DIR/go1.21.5.tar.gz

sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf $WORKING_DIR/go1.21.5.tar.gz

echo "export PATH=\$PATH:/usr/local/go/bin" >> /home/$USER/.bashrc
echo "export PATH=\$PATH:/home/$USER/go/bin" >> /home/$USER/.bashrc
export PATH=$PATH:/usr/local/go/bin
export PATH=$PATH:/home/$USER/go/bin

echo $(go version)

################################################################################
### Install Firecracker and Jailer #############################################
################################################################################

sudo systemctl start docker

git clone https://github.com/loopholelabs/firecracker $WORKING_DIR/firecracker
cd $WORKING_DIR/firecracker

git remote add upstream https://github.com/firecracker-microvm/firecracker
git fetch --all

# Build Firecracker and Jailer
tools/devtool -y build --release

# Install Firecracker and Jailer
sudo install ./build/cargo_target/$MACHINE-unknown-linux-musl/release/{firecracker,jailer} /usr/local/bin/

################################################################################
### Install Drafter ############################################################
################################################################################

git clone https://github.com/loopholelabs/drafter.git $WORKING_DIR/drafter
git clone https://github.com/pojntfx/ltsrpc.git $WORKING_DIR/ltsrpc
git clone https://github.com/pojntfx/r3map.git $WORKING_DIR/r3map

cd $WORKING_DIR/drafter

make depend
make
sudo make install

################################################################################
### Install Architect (Neo) ####################################################
################################################################################

git clone https://$GITHUB_ACCESS_TOKEN@github.com/loopholelabs/architect-neo.git $WORKING_DIR/architect
cd $WORKING_DIR/architect

make depend
make
sudo make install

################################################################################
### Enable KVM #################################################################
################################################################################

### Disabling for AWS AMIs
#sudo modprobe kvm
#sudo tee /etc/modules-load.d/kvm.conf <<EOF
#kvm
#EOF

################################################################################
### Enable NBD #################################################################
################################################################################

sudo modprobe nbd nbds_max=4096
sudo tee /etc/modules-load.d/nbd.conf <<EOF
nbd
EOF

sudo tee /etc/modprobe.d/nbd.conf <<EOF
options nbd nbds_max=4096
EOF

################################################################################
### Architect Worker Service ###################################################
################################################################################

sudo mkdir -p /etc/systemd/system/architect.service.d
sudo mv $WORKING_DIR/architect.service /etc/systemd/system/architect.service
sudo chown root:root /etc/systemd/system/architect.service
sudo systemctl daemon-reload
sudo systemctl disable architect

################################################################################
### Cleanup ####################################################################
################################################################################

sudo systemctl stop docker
sudo yum remove docker -y