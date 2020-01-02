#!/usr/bin/env ruby

# -------------------------------------------------------------------------- #
# Copyright 2002-2019, OpenNebula Project, OpenNebula Systems                #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

$LOAD_PATH.unshift "#{File.dirname(__FILE__)}/../../vmm/lxd/"

require 'container'
require 'client'
require 'base64'

class Domain

    attr_accessor :metrics, :lxc_path, :container

    def initialize(container)
        @container = container
        @lxc_path = 'lxc/' + container.name
        @lxc_path = "#{ENV['LXC_CGROUP_PREFIX']}#{@lxc_path}" if ENV['LXC_CGROUP_PREFIX']

        @metrics = {}
    end

    def usage_memory
        path = "/sys/fs/cgroup/memory/#{@lxc_path}/memory.usage_in_bytes"
        stat = File.read(path).to_i
        @metrics[:mem] = stat / 1024
    rescue StandardError
        @metrics[:mem] = 0
    end

    def usage_cpu
        multiplier = `nproc`.to_i * 100

        cpuj0 = cpu_jiffies

        cpu_used = process_jiffies
        sleep 1 # measure diff
        cpuj1 = cpu_jiffies - cpuj0

        cpu_used = (process_jiffies - cpu_used) / cpuj1
        cpu_used = (cpu_used * multiplier).round(2)

        @metrics[:cpu] = cpu_used
    end

    def usage_network
        netrx = 0
        nettx = 0

        @container.monitor['metadata'].each do |interface, values|
            next if interface == 'lo'

            netrx += values['counters']['bytes_received']
            nettx += values['counters']['bytes_sent']
        end

        @metrics[:netrx] = netrx
        @metrics[:nettx] = nettx
    end

    def to_one
        arch     = @container.architecture
        capacity = @container.expanded_config

        cpu = ''
        vcpu = ''
        mem = ''

        if capacity
            cpu  = capacity['limits.cpu.allowance']
            vcpu = capacity['limits.cpu']
            mem  = capacity['limits.memory']
        end

        cpu  = '50%'  if !cpu || cpu.empty?
        vcpu = '1'    if !vcpu || vcpu.empty?
        mem  = '512MB' if !mem || mem.empty?
        cpu = cpu.chomp('%').to_f / 100
        mem = parse_memory(mem)

        template = <<EOT
NAME="#{@container.name}"
CPU=#{cpu}
VCPU=#{vcpu}
MEMORY=#{mem}
HYPERVISOR="lxd"
IMPORT_VM_ID="#{@container.name}"
OS=[ARCH="#{arch}"]
EOT
        template
    end

    private

    def parse_memory(memory)
        mem_suffix = memory[-2..-1]
        memory = memory[0..-3].to_i # remove sufix
        case mem_suffix[-2..-1]
        when 'GB'
            memory *= 1024
        when 'TB'
            memory *= 1024**2
        end
        memory
    end

end

class DomainList

    CLIENT = LXDClient.new

    def self.info
        containers = Container.get_all(CLIENT)

        return unless containers

        domains = []

        containers.each do |container|
            name = container.name
            domain = Domain.new(container)

            # TODO: Extract to wild.rb
            unless name =~ /^one-\d+/ # Wild VMs
                template = Base64.encode64(domain.to_one).delete("\n")
                domain.metrics[:template] = template
            end

            next unless container.status.casecmp('running').zero?

            domain.usage_memory
            domain.usage_network

            domains.push(name)
        end

        usage_cpu(domains) unless domains.empty?

        metrics = {}
        domains.each do |domain|
            metrics[domain.container.name] = domain.metrics
        end

        metrics
    end

    def usage_cpu(domains)
        multiplier = `nproc`.to_i * 100

        cpuj0 = cpu_jiffies

        domains.each {|domain| domain.metrics[:cpu] = Jiffies.process(domain) }

        sleep 1 # measure diff
        cpuj1 = cpu_jiffies - cpuj0

        domains.each do |domain|
            cpu0 = domain.metrics[:cpu]
            cpu1 = (Jiffies.process(domain) - cpu0) / cpuj1

            domain.metrics[:cpu] = (cpu1 * multiplier).round(2)
        end
    end

    module Jiffies

        def self.process(domain)
            jiffies = 0
            path = "/sys/fs/cgroup/cpu,cpuacct/#{domain.lxc_path}/cpuacct.stat"

            begin
                stat = File.read(path)
            rescue StandardError
                return 0
            end

            stat.lines.each {|line| jiffies += line.split(' ')[1] }

            jiffies.to_f
        end

        def self.cpu
            begin
                stat = File.read('/proc/stat')
            rescue StandardError
                return 0
            end

            jiffies = 0

            # skip cpu string and guest jiffies
            stat.lines.first.split(' ')[1..-3].each do |num|
                jiffies += num.to_i
            end

            jiffies
        end

    end

end
