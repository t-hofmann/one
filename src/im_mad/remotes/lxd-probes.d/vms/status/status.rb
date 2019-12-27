# !/usr/bin/env ruby

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

# TODO: Make container interface a system wide lib
$LOAD_PATH.unshift "#{File.dirname(__FILE__)}/../../../../vmm/lxd/"

require 'container'
require 'client'
require 'base64'
require_relative '../../../lib/poll_common'
require_relative '../../../lib/probe_db'

module LXD

    CLIENT = LXDClient.new

    # Get and translate LXD state to Opennebula monitor state
    #  @param state [String] libvirt state
    #  @return [String] OpenNebula state
    #
    # LXD states for the guest are
    #  * 'running' state refers to containers which are currently active.
    #  * 'frozen' after lxc freeze (suspended).
    #  * 'stopped' container not running or in the process of shutting down.
    #  * 'failure' container have failed.
    def self.one_status(container)
        u = 'UNKNOWN'

        begin
            status = container.status.upcase
        rescue StandardError
            status = U
        end

        case status
        when 'RUNNING'
            status
        when 'FROZEN'
            'PAUSED'
        when 'STOPPED'
            'POWEROFF'

            u if container.config['user.one_status'] == '0'
        when 'FAILURE'
            status
        else
            u
        end
    end

    def self.all_vm_status
        vms = Container.get_all(CLIENT)

        return unless vms

        vms_info = {}
        vms.each do |container|
            vms_info[container.name] = { :state => one_status(container) }
        end

        vms_info
    end

end

################################################################################
# MAIN PROGRAM
################################################################################
caching = true # TODO: Add avoid DB caching option via monitord

vms = all_vm_status(LXD)

return if vms.empty?

if caching == false
    puts "VM_STATE=YES\n#{vms}"
    exit 0
end

time = Time.now.to_i
vms = vms.split("VM=[\n")[1..-1]

db = DB.new(time, 'LXD')

new_data = db.new_status(vms)

return if new_data.empty?

puts "VM_STATUS=YES\n#{new_data}"
