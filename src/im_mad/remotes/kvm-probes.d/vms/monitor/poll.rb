#!/usr/bin/ruby

require_relative '../../../lib/poll_common'
require_relative '../../../lib/kvm_poll'

KVM.load_conf

puts "VM_POLL=YES\n#{all_vm_template(KVM)}"

