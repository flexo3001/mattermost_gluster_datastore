#!/bin/bash

echo "start setting up main nodes"

export DEBIAN_FRONTEND=noninteractive
export DEBIAN_CODENAME=$(lsb_release -cs)
export DEBIAN_VERS=$(lsb_release -rs)

export GLUSTER_DISK=/dev/sdb
export GLUSTER_VOLUME=gv0
export NODE_IPS=(192.168.0.101 192.168.0.102 192.168.0.103)

usage(){
    echo
    echo "Usage: $0 <full|arbiter>"
    echo
    exit 1
}

setup_pre() {
    # upgrade before adding repos
    apt update -y
    apt dist-upgrade -y

    # install prequisites
    apt install -y curl gdisk gnupg2 sshpass
}

setup_containers() {
    # install repo and packages
    curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
    echo "deb [arch=amd64] https://download.docker.com/linux/debian ${DEBIAN_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt update -y &> /dev/null
    apt install -y docker-ce docker-ce-cli docker-compose containerd.io
    systemctl enable --now docker containerd

    mkdir -p /docker_volumes/mattermost/{config,data,logs,plugins,client-plugins}
    chown -R 2000:2000 /docker_volumes/mattermost

    cat > /docker_volumes/docker-compose.yml << EOF
version: "3"
services:
  postgres:
    container_name: postgres_mattermost
    image: postgres:alpine
    restart: unless-stopped
    volumes:
      - /docker_volumes/postgres:/var/lib/postgresql/data
      - /etc/localtime:/etc/localtime:ro
    environment:
      POSTGRES_USER: mmuser
      POSTGRES_PASSWORD: mmuser_password
      POSTGRES_DB: mattermost
    ports:
      - "127.0.0.1:5432:5432"

  app:
    depends_on:
      - postgres
    container_name: mattermost
    image: mattermost/mattermost-enterprise-edition:release-5.25
    restart: unless-stopped
    volumes:
      - /docker_volumes/mattermost/config:/mattermost/config:rw
      - /docker_volumes/mattermost/data:/mattermost/data:rw
      - /docker_volumes/mattermost/logs:/mattermost/logs:rw
      - /docker_volumes/mattermost/plugins:/mattermost/plugins:rw
      - /docker_volumes/mattermost/client-plugins:/mattermost/client/plugins:rw
      - /etc/localtime:/etc/localtime:ro
    environment:
      #MM_SERVICESETTINGS_SITEURL: https://mm.example.com
      MM_LOGSETTINGS_CONSOLELEVEL: debug
      MM_LOGSETTINGS_FILELEVEL: debug
      MM_SQLSETTINGS_DRIVERNAME: postgres
      MM_SQLSETTINGS_DATASOURCE: postgres://mmuser:mmuser_password@postgres:5432/mattermost?sslmode=disable&connect_timeout=10
      MM_PASSWORDSETTINGS_MINIMUMLENGTH: 6
      MM_PASSWORDSETTINGS_SYMBOL: 'false'
      MM_PASSWORDSETTINGS_UPPERCASE: 'false'
    ports:
      - "8065:8065"
EOF

    docker-compose -f /docker_volumes/docker-compose.yml up -d
}

setup_glusterfs() {
    # install repo and packages
    curl -fsSL https://download.gluster.org/pub/gluster/glusterfs/7/rsa.pub | apt-key add -
    echo "deb https://download.gluster.org/pub/gluster/glusterfs/LATEST/Debian/${DEBIAN_VERS}/amd64/apt ${DEBIAN_CODENAME} main" \
        > /etc/apt/sources.list.d/gluster.list

    apt update -y &> /dev/null
    apt install -y glusterfs-client glusterfs-server
    systemctl enable --now glusterd

    sgdisk --clear --new=0:0:0 "$GLUSTER_DISK"
    mkfs.xfs -i size=512 "${GLUSTER_DISK}1"

    mkdir -p /data/brick1/${GLUSTER_VOLUME}
    echo '/dev/sdb1 /data/brick1 xfs defaults 1 2' >> /etc/fstab
    mount -a && mount

    if [[ $1 == "arbiter" ]]; then
        for i in ${NODE_IPS[0]} ${NODE_IPS[1]}; do
            gluster peer probe $i

            if [[ $? != 0 ]]; then
                echo "Gluster: node probing failed."
                gluster peer status
                exit 1
            fi
        done

        # the order of nodes is important
        gluster volume create ${GLUSTER_VOLUME} replica 2 arbiter 1 ${NODE_IPS[0]} ${NODE_IPS[1]} ${NODE_IPS[2]}

        if [[ $? != 0 ]]; then
            echo "Gluster: volume creation failed."
            exit 1
        fi

        gluster volume start ${GLUSTER_VOLUME}
        gluster volume bitrot ${GLUSTER_VOLUME} enable  # bitrot detection
        gluster volume info

        for i in ${NODE_IPS[0]} ${NODE_IPS[1]}; do
            sshpass -p "vagrant" ssh -o StrictHostKeyChecking=no vagrant@${i} \
                'sudo mount -t glusterfs ${NODE_IPS[0]}:/${GLUSTER_VOLUME} /docker_volumes/mattermost/data; \
                echo "${NODE_IPS[0]}:/${GLUSTER_VOLUME} /docker_volumes/mattermost/data glusterfs defaults,_netdev 0 0" | sudo tee -a /etc/fstab'
        done
    fi
}

if [[ $1 == '' && $1 != "arbiter" && $1 != "full" ]]; then
    usage
elif [[ $1 == "arbiter" ]]; then
    setup_pre
    setup_glusterfs
elif [[ $1 == "full" ]]; then
    setup_pre
    setup_glusterfs
    setup_containers
fi
