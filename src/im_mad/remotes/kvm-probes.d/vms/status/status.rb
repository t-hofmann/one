#!/usr/bin/ruby

require_relative '../../../lib/poll_common'
require_relative '../../../lib/kvm_poll'
require_relative '../../../lib/probe_db'

module KVM

    def self.all_vm_status
        vms_info = {}
        vms = {}

        text = `#{virsh(:list)}`

        return if $?.exitstatus != 0

        lines = text.split(/\n/)[2..-1]

        names = lines.map do |line|
            line.split(/\s+/).delete_if {|d| d.empty? }[1]
        end

        return vms_info if names.empty?

        names.each do |vm|
            dominfo = dom_info(vm)

            next unless dominfo

            info = {}

            info[:dominfo] = dominfo
            info[:name]    = vm
            info[:reason]  = dom_state_reason(vm)

            vms[vm] = info
        end

        vms.each do |name, vm|
            dominfo = vm[:dominfo]

            values = {}

            values[:state] = get_state(dominfo['State'], vm[:reason])

            if !name.match(/^one-\d+/)
                xml = dump_xml(name)

                uuid, template = xml_to_one(xml)
                values[:template] = Base64.encode64(template).delete("\n")
                values[:vm_name] = name
                vm[:name] = uuid
            end

            vms_info[vm[:name]] = values
        end

        vms_info
    end

end

KVM.load_conf
caching = true # TODO: Add avoid DB caching option via monitord

vms = all_vm_status(KVM)

return if vms.empty?

if caching == false
    puts "VM_STATE=YES\n#{vms}"
    exit 0
end

time = Time.now.to_i

vms = vms.split("VM=[\n")[1..-1]

db = DB.new(time, 'KVM')

new_data = db.new_status(vms)

return if new_data.empty?

puts "VM_STATE=YES\n#{new_data}"
