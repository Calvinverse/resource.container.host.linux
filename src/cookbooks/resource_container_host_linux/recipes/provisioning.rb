# frozen_string_literal: true

#
# Cookbook Name:: resource_container_host_linux
# Recipe:: provisioning
#
# Copyright 2017, P. van der Velde
#

#
# INSTALL DOS2UNIX
#

apt_package 'dos2unix' do
  action :install
end

#
# INSTALL PWGEN
#

apt_package 'pwgen' do
  action :install
end

#
# CONFIGURE THE PROVISIONING SCRIPT
#

# Create the provisioning script
file '/etc/init.d/provision.sh' do
  action :create
  content <<~BASH
    #!/bin/bash

    function f_getEth0Ip {
      local _ip _line
      while IFS=$': \t' read -a _line ;do
          [ -z "${_line%inet}" ] &&
            _ip=${_line[${#_line[1]}>4?1:2]} &&
            [ "${_ip#127.0.0.1}" ] && echo $_ip && return 0
        done< <(LANG=C /sbin/ifconfig eth0)
    }

    function f_setHostName {
      # Generate a 16 character password
      POSTFIX=$(pwgen --no-capitalize 16 1)

      NAME="cvcontainerhost-${RESOURCE_VERSION_MAJOR}-${RESOURCE_VERSION_MINOR}-${RESOURCE_VERSION_PATCH}-${POSTFIX}"
      sudo hostnamectl set-hostname $NAME
    }

    FLAG="/var/log/firstboot.log"
    if [ ! -f $FLAG ]; then

      f_setHostName

      IPADDRESS=$(f_getEth0Ip)

      #
      # CREATE MACHINE SPECIFIC CONFIGURATION FILES
      #
      # Create '/etc/consul/conf.d/connections.json'
      echo "{ \\"advertise_addr\\": \\"${IPADDRESS}\\", \\"bind_addr\\": \\"${IPADDRESS}\\" }"  > /etc/consul/conf.d/connections.json

      # Create '/etc/nomad-conf.d/connections.hcl'
      echo -e "bind_addr = \\"${IPADDRESS}\\"\\n advertise {\\n  http = \\"${IPADDRESS}\\"\\n  rpc = \\"${IPADDRESS}\\"\\n  serf = \\"${IPADDRESS}\\"\\n}"  > /etc/nomad-conf.d/connections.hcl

      #
      # MOUNT THE DVD WITH THE CONFIGURATION FILES
      #
      if [ ! -d /mnt/dvd ]; then
        mkdir /mnt/dvd
      fi
      mount /dev/dvd /mnt/dvd

      #
      # CONFIGURE SSH
      #
      # If the allow SSH file is not there, disable SSH in the firewall
      if [ ! -f /mnt/dvd/allow_ssh.json ]; then
        ufw deny 22
      fi

      #
      # CONSUL CONFIGURATION
      #
      # Stop the consul service and kill the data directory. It will have the consul node-id in it which must go!
      sudo systemctl stop consul.service
      sudo rm -rfv /var/lib/consul/*

      cp -a /mnt/dvd/consul/consul_region.json /etc/consul/conf.d/region.json
      dos2unix /etc/consul/conf.d/region.json

      cp -a /mnt/dvd/consul/consul_secrets.json /etc/consul/conf.d/secrets.json
      dos2unix /etc/consul/conf.d/secrets.json

      cp -a /mnt/dvd/consul/client/consul_client_location.json /etc/consul/conf.d/location.json
      dos2unix /etc/consul/conf.d/location.json

      #
      # DOCKER CONFIGURATION
      #
      # Set up the docker configuration to include the insecure registries
      cp -a /mnt/dvd/docker/daemon.json /etc/docker/daemon.json
      dos2unix /etc/docker/daemon.json

      # Restart the service so that it picks up the new configuration
      sudo systemctl restart docker.service

      # Copy the script that will be used to create the Docker MacVlan network
      cp -a /mnt/dvd/get_docker_subnet_information.sh /tmp/get_docker_subnet_information.sh
      dos2unix /tmp/get_docker_subnet_information.sh

      # Run the script that creates the Docker network connection
      . /tmp/get_docker_subnet_information.sh

      ADDRESS_SPACE=$(f_getPrivateAddressSpace $IPADDRESS)
      IPRANGE=$(f_getContainerSubnet $IPADDRESS)
      GATEWAY=$(f_getContainerGateway $IPADDRESS)
      VLANTAG=$(f_getVlanTag)
      if [[ $VLANTAG != '' && $VLANTAG != .* ]]; then
        VLANTAG=".${VLANTAG}"
      fi

      docker network create -d macvlan --subnet=$ADDRESS_SPACE --ip-range=$IPRANGE --gateway=$GATEWAY -o parent=eth0${VLANTAG} docker_macvlan

      #
      # NOMAD CONFIGURATION
      #
      cp -a /mnt/dvd/nomad/nomad_region.hcl /etc/nomad-conf.d/region.hcl
      dos2unix /etc/nomad-conf.d/region.hcl

      cp -a /mnt/dvd/nomad/nomad_secrets.hcl /etc/nomad-conf.d/secrets.hcl
      dos2unix /etc/nomad-conf.d/secrets.hcl

      #
      # UNBOUND CONFIGURATION
      #
      cp -a /mnt/dvd/unbound/unbound_zones.conf /etc/unbound.d/unbound_zones.conf
      dos2unix /etc/unbound.d/unbound_zones.conf

      #
      # UNMOUNT DVD
      #
      umount /dev/dvd
      eject -T /dev/dvd

      #
      # ENABLE SERVICES
      #
      sudo systemctl enable unbound.service
      sudo systemctl enable nomad.service

      # The next line creates an empty file so it won't run the next boot
      touch $FLAG

      # restart the machine so that all configuration settings take hold
      sudo shutdown -r now
    else
      echo "Provisioning script ran previously so nothing to do"
    fi
  BASH
  mode '755'
end

# Create the service that is going to run the script
file '/etc/systemd/system/provision.service' do
  action :create
  content <<~SYSTEMD
    [Unit]
    Description=Provision the environment
    Requires=network-online.target
    After=network-online.target

    [Service]
    Type=oneshot
    ExecStart=/etc/init.d/provision.sh
    RemainAfterExit=true
    EnvironmentFile=-/etc/environment

    [Install]
    WantedBy=network-online.target
  SYSTEMD
end

# Make sure the service starts on boot
service 'provision.service' do
  action [:enable]
end
