#!/usr/bin/ruby

require_relative '../../../lib/kvm'

KVM.load_conf

vms = DomainList.wild_info

puts DomainList.wilds_to_monitor(vms)
