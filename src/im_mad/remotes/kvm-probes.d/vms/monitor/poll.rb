#!/usr/bin/ruby

require_relative '../../../lib/kvm'

KVM.load_conf

vms = DomainList.info

puts DomainList.to_monitor(vms)
