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

################################################################################
### Generate Base Drafter Image ################################################
################################################################################
generate_base_image() {
 export GATEWAY_IP="172.100.100.1"
 export GUEST_CIDR="172.100.100.2/30"
 export LIVENESS_VSOCK_PORT="25"
 export AGENT_VSOCK_PORT="26"

 qemu-img create -f raw $WORKING_DIR/blueprint/$APPLICATION_NAME.drftdisk ${DISK_SIZE}
 mkfs.ext4 -F $WORKING_DIR/blueprint/$APPLICATION_NAME.drftdisk

 sudo umount $WORKING_DIR/mnt/blueprint || true
 rm -rf $WORKING_DIR/mnt/blueprint
 mkdir -p $WORKING_DIR/mnt/blueprint

 sudo mount $WORKING_DIR/blueprint/$APPLICATION_NAME.drftdisk $WORKING_DIR/mnt/blueprint
 sudo chown ${USER} $WORKING_DIR/mnt/blueprint

 curl -Lo $WORKING_DIR/rootfs.tar.gz https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/x86_64/alpine-minirootfs-3.18.4-x86_64.tar.gz
 tar zxvf $WORKING_DIR/rootfs.tar.gz -C $WORKING_DIR/mnt/blueprint

 tee $WORKING_DIR/mnt/blueprint/etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
EOF

 tee $WORKING_DIR/mnt/blueprint/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
 address ${GUEST_CIDR}
 gateway ${GATEWAY_IP}
EOF

 sudo chroot $WORKING_DIR/mnt/blueprint sh - <<'EOF'
apk add alpine-base util-linux linux-virt linux-virt-dev coreutils binutils grep bzip2 chrony haveged
echo root:root | chpasswd

ln -s agetty /etc/init.d/agetty.ttyS0
echo ttyS0 >/etc/securetty
rc-update add agetty.ttyS0 default

sed -i 's/initstepslew/#initstepslew/g' /etc/chrony/chrony.conf
echo 'refclock PHC /dev/ptp0 poll 3 dpoll -2 offset 0' >> /etc/chrony/chrony.conf

rc-update add networking default
rc-update add chronyd default
rc-update add haveged default
EOF

 cd $WORKING_DIR/drafter
 CGO_ENABLED=0 go build -o $WORKING_DIR/mnt/blueprint/usr/sbin/drafter-liveness ./cmd/drafter-liveness

 tee $WORKING_DIR/mnt/blueprint/etc/init.d/drafter-liveness <<EOF
#!/sbin/openrc-run

command="/usr/sbin/drafter-liveness"
command_args="--vsock-port ${LIVENESS_VSOCK_PORT}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/dev/stdout"
error_log="/dev/stderr"

depend() {
  need net ${SERVICE_DEPENDENCY} drafter-agent
}
EOF

 chmod +x $WORKING_DIR/mnt/blueprint/etc/init.d/drafter-liveness

 sudo chroot $WORKING_DIR/mnt/blueprint sh - <<'EOF'
rc-update add drafter-liveness default
EOF

 cd $WORKING_DIR/lynk
 CGO_ENABLED=0 go build -o $WORKING_DIR/mnt/blueprint/usr/sbin/drafter-agent ./cmd/lynark-agent

 tee $WORKING_DIR/mnt/blueprint/etc/init.d/drafter-agent <<EOF
#!/sbin/openrc-run

command="/usr/sbin/drafter-agent"
command_args="--vsock-port ${AGENT_VSOCK_PORT} --control-plane-raddr ${LYNK_CONTROL_PLANE_ADDR} --data-plane-raddr ${LYNK_DATA_PLANE_ADDR} --upstream-raddr ${LYNK_UPSTREAM_ADDR}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/dev/stdout"
error_log="/dev/stderr"

depend() {
	need net ${SERVICE_DEPENDENCY}
}
EOF
 chmod +x $WORKING_DIR/mnt/blueprint/etc/init.d/drafter-agent

 sudo chroot $WORKING_DIR/mnt/blueprint sh - <<'EOF'
rc-update add drafter-agent default
EOF
}

################################################################################
### Clean Up Base Drafter Image ################################################
################################################################################
cleanup_base_image() {
 sudo cp $WORKING_DIR/mnt/blueprint/boot/initramfs-virt $WORKING_DIR/blueprint/$APPLICATION_NAME.drftinitramfs
 sudo chown ${USER} $WORKING_DIR/blueprint/$APPLICATION_NAME.drftinitramfs

 sudo umount $WORKING_DIR/mnt/blueprint || true
 rm -rf $WORKING_DIR/mnt/blueprint
}

validate_env_set WORKING_DIR
validate_env_set USER
validate_env_set GITHUB_ACCESS_TOKEN
validate_env_set LYNK_CONTROL_PLANE_ADDR
validate_env_set LYNK_DATA_PLANE_ADDR

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
  flex

################################################################################
### Install Golang #############################################################
################################################################################

wget "https://go.dev/dl/go1.21.5.linux-$ARCH.tar.gz" -O $WORKING_DIR/go1.21.5.tar.gz

sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf $WORKING_DIR/go1.21.5.tar.gz

echo 'export PATH=$PATH:/usr/local/go/bin' >> /home/$USER/.bashrc
export PATH=$PATH:/usr/local/go/bin

echo $(go version)

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
### Install Lynk ############################################################
################################################################################

git clone https://$GITHUB_ACCESS_TOKEN@github.com/loopholelabs/lynark.git $WORKING_DIR/lynk

cd $WORKING_DIR/lynk
make depend
make

################################################################################
### Generate Firecracker Linux Kernel 5.10 #####################################
################################################################################

rm -rf $WORKING_DIR/blueprint
mkdir -p $WORKING_DIR/blueprint

rm -rf $WORKING_DIR/kernel
mkdir -p $WORKING_DIR/kernel

curl -Lo $WORKING_DIR/kernel.tar.xz https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.10.194.tar.xz
tar Jxvf $WORKING_DIR/kernel.tar.xz --strip-components=1 -C $WORKING_DIR/kernel

curl -Lo $WORKING_DIR/kernel/.config https://raw.githubusercontent.com/loopholelabs/firecracker/live-migration-1.6-main-1/resources/guest_configs/microvm-kernel-ci-x86_64-5.10.config

sh - <<'EOF'
cd $WORKING_DIR/kernel

make -j$(nproc) vmlinux
EOF

cp $WORKING_DIR/kernel/vmlinux $WORKING_DIR/blueprint/drafter.drftkernel

################################################################################
### Generate Base Redis Image ##################################################
################################################################################

export DISK_SIZE="384M"
export APPLICATION_NAME="redis"
export SERVICE_DEPENDENCY="redis"
export LYNK_UPSTREAM_ADDR="localhost:6379"

generate_base_image

sudo chroot $WORKING_DIR/mnt/blueprint sh - <<'EOF'
apk add redis redis-openrc

rc-update add redis default
EOF

cleanup_base_image

################################################################################
### Generate Base Minecraft Image ##############################################
################################################################################

export DISK_SIZE="1536M"
export APPLICATION_NAME="minecraft"
export SERVICE_DEPENDENCY="minecraft-server"
export LYNK_UPSTREAM_ADDR="localhost:25565"

generate_base_image

if [ ! -d $WORKING_DIR/mnt/blueprint/root/cuberite ]; then
    git clone --recursive https://github.com/cuberite/cuberite.git $WORKING_DIR/mnt/blueprint/root/cuberite
fi

sudo chroot $WORKING_DIR/mnt/blueprint sh - <<'EOF'
apk add build-base git python3 perl clang cmake expect bash

cd /root

if [ ! -f /cuberite/Release/Server/Cuberite ]; then
    mkdir -p cuberite/Release
    cd cuberite/Release

    cmake -DCMAKE_BUILD_TYPE=RELEASE .. -DCMAKE_CXX_COMPILER=/usr/bin/clang++
    make -l

    tee Server/settings.ini <<EOL
; This is the main server configuration
; Most of the settings here can be configured using the webadmin interface, if enabled in webadmin.ini

[Authentication]
Authenticate=0
AllowBungeeCord=0
OnlyAllowBungeeCord=0
ProxySharedSecret=
Server=sessionserver.mojang.com
Address=/session/minecraft/hasJoined?username=%USERNAME%&serverId=%SERVERID%

[MojangAPI]
NameToUUIDServer=api.mojang.com
NameToUUIDAddress=/profiles/minecraft
UUIDToProfileServer=sessionserver.mojang.com
UUIDToProfileAddress=/session/minecraft/profile/%UUID%?unsigned=false

[Server]
Description=Minecraft on Drafter
ShutdownMessage=Server shutdown
MaxPlayers=20
HardcoreEnabled=0
AllowMultiLogin=0
RequireResourcePack=0
ResourcePackUrl=
CustomRedirectUrl=https://youtu.be/dQw4w9WgXcQ
Ports=25565
AllowMultiWorldTabCompletion=1
DefaultViewDistance=10

[RCON]
Enabled=0

[AntiCheat]
LimitPlayerBlockChanges=0

[Worlds]
DefaultWorld=world
World=world_nether
World=world_the_end

[WorldPaths]
world=world
world_nether=world_nether
world_the_end=world_the_end

[Plugins]
Core=1
ChatLog=1
ProtectionAreas=0

[DeadlockDetect]
Enabled=1
IntervalSec=20

[Seed]
Seed=775375601

[SpawnPosition]
MaxViewDistance=10
X=0.500000
Y=115.000000
Z=0.500000
PregenerateDistance=20
EOL
fi

mkdir -p /root/.cache/
EOF

tee $WORKING_DIR/mnt/blueprint/etc/init.d/minecraft-server <<EOF
#!/sbin/openrc-run

command="/bin/bash"
command_args="-c 'cp -r /root/cuberite/Release/Server/* /run && cd /run && unbuffer ./Cuberite'"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/dev/stdout"
error_log="/dev/stderr"

depend() {
	need net
}
EOF
chmod +x $WORKING_DIR/mnt/blueprint/etc/init.d/minecraft-server

sudo chroot $WORKING_DIR/mnt/blueprint sh - <<'EOF'
rc-update add minecraft-server default
EOF

cleanup_base_image

################################################################################
### Generate Base PostgreSQL Image #############################################
################################################################################

export DISK_SIZE="1536M"
export APPLICATION_NAME="postgresql"
export SERVICE_DEPENDENCY="postgresql"
export LYNK_UPSTREAM_ADDR="localhost:5432"

generate_base_image

sudo mount --bind /dev $WORKING_DIR/mnt/blueprint/dev

sudo chroot $WORKING_DIR/mnt/blueprint sh - <<'EOF'
apk add postgresql postgresql-client

rc-update add postgresql default

su postgres -c "initdb -D /var/lib/postgresql/data"

echo "host all all 0.0.0.0/0 trust" > /var/lib/postgresql/data/pg_hba.conf
echo "listen_addresses='*'" >> /var/lib/postgresql/data/postgresql.conf
EOF

sudo umount $WORKING_DIR/mnt/blueprint/dev || true

cleanup_base_image