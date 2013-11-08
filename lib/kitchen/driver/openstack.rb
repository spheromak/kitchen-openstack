# -*- encoding: utf-8 -*-
#
# Author:: Jonathan Hartman (<j@p4nt5.com>)
#
# Copyright (C) 2013, Jonathan Hartman
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'benchmark'
require 'fog'
require 'kitchen'
require 'etc'
require 'ipaddr'
require 'socket'

module Kitchen
  module Driver
    # Openstack driver for Kitchen.
    #
    # @author Jonathan Hartman <j@p4nt5.com>
    class Openstack < Kitchen::Driver::SSHBase
      @@ip_pool_lock = Mutex.new

      default_config :name, nil
      default_config :key_name, nil
      default_config :private_key_path do |driver|
        %w{id_rsa id_dsa}.collect do |k|
          f = File.expand_path "~/.ssh/#{k}"
          f if File.exists? f
        end.compact.first
      end
      default_config :public_key_path do |driver|
        driver[:private_key_path] + '.pub'
      end
      default_config :username, 'root'
      default_config :port, '22'
      default_config :use_ipv6, false
      default_config :openstack_tenant, nil
      default_config :openstack_region, nil
      default_config :openstack_service_name, nil
      default_config :openstack_network_name, nil
      default_config :floating_ip_pool, nil
      default_config :floating_ip, nil

      def create(state)
        config[:name] ||= generate_name(instance.name)
        config[:disable_ssl_validation] and disable_ssl_validation
        server = create_server
        state[:server_id] = server.id
        info "OpenStack instance <#{state[:server_id]}> created."
        server.wait_for { print '.'; ready? } ; info "\n(server ready)"
        if config[:floating_ip_pool]
          attach_ip_from_pool(server, config[:floating_ip_pool])
        elsif config[:floating_ip]
          attach_ip(server, config[:floating_ip])
        end
        state[:hostname] = get_ip(server)
        state[:ssh_key] = config[:private_key_path]
        wait_for_sshd(state[:hostname]) ; info '(ssh ready)'
        if config[:key_name]
          info "Using OpenStack keypair <#{config[:key_name]}>"
        end
        info "Using public SSH key <#{config[:public_key_path]}>"
        info "Using private SSH key <#{config[:private_key_path]}>"
        unless config[:key_name]
          do_ssh_setup(state, config, server)
        end
      rescue Fog::Errors::Error, Excon::Errors::Error => ex
        raise ActionFailed, ex.message
      end

      def destroy(state)
        return if state[:server_id].nil?

        config[:disable_ssl_validation] and disable_ssl_validation
        server = compute.servers.get(state[:server_id])
        server.destroy unless server.nil?
        info "OpenStack instance <#{state[:server_id]}> destroyed."
        state.delete(:server_id)
        state.delete(:hostname)
      end

      private

      def compute
        server_def = {
          :provider           => 'OpenStack',
          :openstack_username => config[:openstack_username],
          :openstack_api_key  => config[:openstack_api_key],
          :openstack_auth_url => config[:openstack_auth_url]
        }
        optional = [
          :openstack_tenant, :openstack_region, :openstack_service_name, :metadata
        ]
        optional.each do |o|
          config[o] and server_def[o] = config[o]
        end
        Fog::Compute.new(server_def)
      end

      def create_server
        image = find_matching(compute.images, config[:image_ref])
        raise ActionFailed, "Image not found" if !image
        debug "Selected image: #{image.id} #{image.name}"

        flavor = find_matching(compute.flavors, config[:flavor_ref])
        raise ActionFailed, "Flavor not found" if !flavor
        debug "Selected flavor: #{flavor.id} #{flavor.name}"

        server_def = {
          :name => config[:name],
          :image_ref => image.id,
          :flavor_ref => flavor.id
        }
        if config[:public_key_path]
          server_def[:public_key_path] = config[:public_key_path]
        end
        server_def[:key_name] = config[:key_name] if config[:key_name]
        # Can't use the Fog bootstrap and/or setup methods here; they require a
        # public IP address that can't be guaranteed to exist across all
        # OpenStack deployments (e.g. TryStack ARM only has private IPs).
        compute.servers.create(server_def)
      end

      def generate_name(base)
        # Generate what should be a unique server name
        sep = '-'
        pieces = [
          base,
          Etc.getlogin,
          Socket.gethostname,
          Array.new(8) { rand(36).to_s(36) }.join
        ]
        until pieces.join(sep).length <= 64 do
          if pieces[2].length > 24
            pieces[2] = pieces[2][0..-2]
          elsif pieces[1].length > 16
            pieces[1] = pieces[1][0..-2]
          elsif pieces[0].length > 16
            pieces[0] = pieces[0][0..-2]
          end
        end
        pieces.join sep
      end

      def attach_ip_from_pool(server, pool)
        @@ip_pool_lock.synchronize do
          info "Attaching floating IP from <#{pool}> pool"
          free_addrs = compute.addresses.collect do |i|
            i.ip if i.fixed_ip.nil? and i.instance_id.nil? and i.pool == pool
          end.compact
          if free_addrs.empty?
            raise ActionFailed, "No available IPs in pool <#{pool}>"
          end
          attach_ip(server, free_addrs[0])
        end
      end

      def attach_ip(server, ip)
        info "Attaching floating IP <#{ip}>"
        server.associate_address ip
        (server.addresses['public'] ||= []) << { 'version' => 4, 'addr' => ip }
      end

      def get_ip(server)
        if config[:openstack_network_name]
          debug "Using configured network: #{config[:openstack_network_name]}"
          return server.addresses[config[:openstack_network_name]].first['addr']
        end
        begin
          pub, priv = server.public_ip_addresses, server.private_ip_addresses
        rescue Fog::Compute::OpenStack::NotFound
          # See Fog issue: https://github.com/fog/fog/issues/2160
          addrs = server.addresses
          addrs['public'] and pub = addrs['public'].map { |i| i['addr'] }
          addrs['private'] and priv = addrs['private'].map { |i| i['addr'] }
        end
        pub, priv = parse_ips(pub, priv)
        pub.first || priv.first || raise(ActionFailed, 'Could not find an IP')
      end

      def parse_ips(pub, priv)
        pub, priv = Array(pub), Array(priv)
        if config[:use_ipv6]
          [pub, priv].each { |n| n.select! { |i| IPAddr.new(i).ipv6? } }
        else
          [pub, priv].each { |n| n.select! { |i| IPAddr.new(i).ipv4? } }
        end
        return pub, priv
      end

      def do_ssh_setup(state, config, server)
        info "Setting up SSH access for key <#{config[:public_key_path]}>"
        ssh = Fog::SSH.new(state[:hostname], config[:username],
          { :password => server.password })
        pub_key = open(config[:public_key_path]).read
        ssh.run([
          %{mkdir .ssh},
          %{echo "#{pub_key}" >> ~/.ssh/authorized_keys},
          %{passwd -l #{config[:username]}}
        ])
      end

      def disable_ssl_validation
        require 'excon'
        Excon.defaults[:ssl_verify_peer] = false
      end

      def find_matching(collection, name)
        name = name.to_s
        if name.start_with?('/')
          regex = eval(name)
          # check for regex name match
          collection.each do |single|
            return single if regex =~ single.name
          end
        else
          # check for exact id match
          collection.each do |single|
            return single if single.id == name
          end
          # check for exact name match
          collection.each do |single|
            return single if single.name == name
          end
        end
        nil
      end

    end
  end
end

# vim: ai et ts=2 sts=2 sw=2 ft=ruby
