#!/usr/bin/ruby

require_relative '../../../lib/kvm'
require_relative '../../../lib/probe_db'

KVM.load_conf

begin
    vmdb = VirtualMachineDB.new('kvm', :missing_state => 'POWEROFF')

    vmdb.purge

    puts vmdb.to_status

rescue StandardError => e
    puts e
end
