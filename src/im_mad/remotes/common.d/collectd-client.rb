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

require 'socket'
require 'base64'
require 'resolv'
require 'ipaddr'
require 'zlib'
require 'yaml'
require 'open3'
require 'openssl'

require 'rexml/document'


#  This class represents a monitord client. It handles udp and tcp connections
#  and send update messages to monitord
#
class MonitorClient

    # Defined in src/monitor/include/MonitorDriverMessages.h
    MESSAGE_TYPES = %w[MONITOR_VM MONITOR_HOST SYSTEM_HOST STATE_VM
                       START_MONITOR STOP_MONITOR].freeze

    MESSAGE_STATUS = { true =>'SUCCESS', false => 'FAILURE' }.freeze

    MESSAGE_TYPES.each do |mt|
        define_method(mt.downcase.to_sym) do |rc, payload|
            msg = "#{mt} #{MESSAGE_STATUS[rc]} #{@hostid} #{pack(payload)}"
            @socket_udp.send(msg, 0)
        rescue StandardError
        end
    end

    # Options to create a monitord client
    # :host [:String] to send the messages to
    # :port [:String] of monitord server
    # :hostid [:String] OpenNebula ID of this host
    # :pubkey [:String] public key to encrypt messages
    def initialize(server, port, id, opt = {})
        @opts = {
            :pubkey => ''
        }.merge opt

        addr = Socket.getaddrinfo(server, port)[0]

        @socket_udp = UDPSocket.new(addr[0])
        @socket_udp.connect(addr[3], addr[1])

        if @opts[:pubkey].empty?
            @pubkey = nil
        else
            @pubkey = OpenSSL::PKey::RSA.new @opts[:pubkey]
        end

        @hostid = id
    end

    private

    # Formats message payload to send over the wire
    def pack(data)
        zdata  = Zlib::Deflate.deflate(data, Zlib::BEST_COMPRESSION)
        data64 = Base64.strict_encode64(zdata)

        if @pubkey
            @key_pub.public_encrypt(data64)
        else
            data64
        end
    end

end

#  This class wraps the execution of a probe directory and sends data to
#  monitord (optionally)
#
class ProbeRunner

    def initialize(hyperv, path)
        @path = File.join(File.dirname(__FILE__), '..', "#{hyperv}-probes.d",
                          path)
    end

    def run_probes
        cwd_bck = Dir.pwd
        Dir.chdir(@path)

        data = ''

        Dir.each_child(@path) do |probe|
            next unless File.executable?(probe)

            data += `./#{probe} 2>&1`

            return [-1, "Error executing #{probe}"] if $?.exitstatus != 0
        end

        Dir.chdir(cwd_bck)

        [0, data]
    end

    def self.monitor_loop(hyperv, path, period, &block)
        runner = ProbeRunner.new(hyperv, path)

        loop do
            ts = Time.now

            rc, data = runner.run_probes

            block.call(rc, data)

            run_time = (Time.now - ts).to_i

            sleep(period.to_i - run_time) if period.to_i > run_time
        end
    end

end

#-------------------------------------------------------------------------------
# Configuration (from monitord)
#-------------------------------------------------------------------------------
xml_txt = STDIN.read

begin
    config = REXML::Document.new(xml_txt).root

    host   = config.elements['UDP_LISTENER/MONITOR_ADDRESS'].text.to_s
    port   = config.elements['UDP_LISTENER/PORT'].text.to_s
    pubkey = config.elements['UDP_LISTENER/PUBKEY'].text.to_s
    hyperv = ARGV[0]

    probes = {
        :system_host => {
            :period => config.elements['PROBE_PERIOD/SYSTEM_HOST'].text.to_s,
            :path => 'host/system'
        },

        :monitor_host => {
            :period => config.elements['PROBE_PERIOD/MONITOR_HOST'].text.to_s,
            :path => 'host/monitor'
        },

        :state_vm => {
            :period => config.elements['PROBE_PERIOD/VMS'].text.to_s,
            :path => 'vm/status'
        },

        :monitor_vm => {
            :period => config.elements['PROBE_PERIOD/VMM'].text.to_s,
            :path => 'vm/monitor'
        },
    }

rescue StandardError => e
    puts e.inspect
    exit(-1)
end

#-------------------------------------------------------------------------------
# Run configuration probes and send information to monitord
#-------------------------------------------------------------------------------
client = MonitorClient.new(host, port, 0, :pubkey => pubkey)
# TODO: execute host/system + datastore/monitor
# TODO: get host id from probe arguments

#-------------------------------------------------------------------------------
# Start monitor threads and shepherd
#-------------------------------------------------------------------------------
threads = []

probes.each do |msg_type, conf|
    threads << Thread.new {
        ProbeRunner.monitor_loop(hyperv, conf[:path], conf[:period]) do |rc, da|
            client.send(msg_type, rc, da)
        end
    }
end

threads << Thread.new do
    sleep 60
    `#{__dir__}/../#{hypervisor}-probes.d/collectd-client-shepherd.sh`
end
threads.each {|thr| thr.join }
