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

$LOAD_PATH.unshift "#{File.dirname(__FILE__)}/../../../../vmm/lxd/"

require 'container'
require 'client'
require 'base64'
require_relative '../../../lib/poll_common'

################################################################################
#
#  LXD Monitor Module
#
################################################################################
module LXD

    CLIENT = LXDClient.new

    class << self

        # Get the information of a single VM. In case of error the VM is reported
        # as not found.
        # @param one_vm [String] with the VM name
        def get_vm_info(one_vm)
            vm = Container.get(one_vm, nil, CLIENT)

            return { :state => '-' } unless vm

            get_values([vm]).first.last
        end

        # Gets the information of all VMs
        #
        # @return [Hash, nil] Hash with the VM information or nil in case of error
        def all_vm_info
            vms = Container.get_all(CLIENT)

            return unless vms

            get_values(vms)
        end

        def get_values(vms)
            vms_info = {}

            running_containers = []

            vms.each do |container|
                values = {}
                name = container.name

                unless name =~ /^one-\d+/ # Wild VMs
                    template = to_one(container)
                    values[:template] = Base64.encode64(template).delete("\n")
                    values[:vm_name] = name
                end

                vms_info[name] = values
                next unless container.status.casecmp('running').zero?

                vmd = container.monitor['metadata']

                values[:memory] = get_memory(name)
                values[:netrx], values[:nettx] = get_net_statistics(vmd['network'])

                running_containers.push(name)
                vms_info[name][:memory] = values[:memory]
            end

            unless running_containers.empty?
                cpu = get_cpu(running_containers)
                vms.each do |container|
                    vms_info[container.name][:cpu] = cpu[container.name] if cpu[container.name]
                end
            end

            vms_info
        end

        def lxc_path(vm_name)
            path = 'lxc/' + vm_name
            "#{ENV['LXC_CGROUP_PREFIX']}#{path}" if ENV['LXC_CGROUP_PREFIX']
        end

        def get_memory(vm_name)
            stat = File.read('/sys/fs/cgroup/memory/' + lxc_path(vm_name) + '/memory.usage_in_bytes').to_i
            stat / 1024
        rescue StandardError
            0
        end

        def get_net_statistics(vmd)
            netrx = 0
            nettx = 0

            vmd.each do |interface, values|
                next if interface == 'lo'

                netrx += values['counters']['bytes_received']
                nettx += values['counters']['bytes_sent']
            end

            [netrx, nettx]
        end

        # Gathers process information from a set of VMs.
        #   @param vm_names [Array] of vms indexed by name. Value is a hash with :pid
        #   @return  [Hash] with ps information
        def get_cpu(vm_names)
            multiplier = `nproc`.to_i * 100

            start_cpu_jiffies = get_cpu_jiffies

            cpu_used = {}
            vm_names.each do |vm_name|
                cpu_used[vm_name] = get_process_jiffies(vm_name).to_f
            end

            sleep 1

            cpu_jiffies = get_cpu_jiffies - start_cpu_jiffies

            vm_names.each do |vm_name|
                cpu_used[vm_name] = (get_process_jiffies(vm_name).to_f -
                        cpu_used[vm_name]) / cpu_jiffies

                cpu_used[vm_name] = (cpu_used[vm_name] * multiplier).round(2)
            end

            cpu_used
        end

        def get_cpu_jiffies
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

        def get_process_jiffies(vm_name)
            begin
                jiffies = 0

                stat = File.read('/sys/fs/cgroup/cpu,cpuacct/' + lxc_path(vm_name) + '/cpuacct.stat')
                stat.lines.each {|line| jiffies += line.split(' ')[1] }
            rescue StandardError
                return 0
            end

            jiffies
        end

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

        def to_one(container)
            name     = container.name
            arch     = container.architecture
            capacity = container.expanded_config

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
NAME="#{name}"
CPU=#{cpu}
VCPU=#{vcpu}
MEMORY=#{mem}
HYPERVISOR="lxd"
IMPORT_VM_ID="#{name}"
OS=[ARCH="#{arch}"]
EOT
            template
        end

    end

end

################################################################################
# MAIN PROGRAM
################################################################################

puts "VM_POLL=YES\n#{all_vm_template(LXD)}"