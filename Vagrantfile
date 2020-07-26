NODE_IPS = ['192.168.0.101', '192.168.0.102', '192.168.0.103']

Vagrant.configure("2") do |config|
  config.vm.box = "debian/buster64"
  config.vm.provider "virtualbox"

  NODE_IPS.each_with_index do |node_ip, i|
    config.vm.define "node#{i + 1}" do |box|
      box.vm.hostname = "node#{i + 1}"
      box.vm.disk :disk, name: "gluster#{i + 1}", size: "10GB"
      box.vm.network "forwarded_port", guest: 8065, host: "#{i + 1}8065".to_i
      box.vm.network "private_network", ip: node_ip

      if i == 2
        ARG = "arbiter"
      else
        ARG = "full"
      end

      box.vm.provision :shell do |s|
        s.path = 'setup.sh'
        s.args = ["#{ARG}"]
        #s.reboot = true
      end
    end
  end
end
