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

require 'yaml'
require 'fileutils'

yaml = YAML.load(STDIN.read).to_hash

class DSMonitor

    def initialize(probe_args)
        @ds_location = probe_args[:ds_location]
        @ds_location ||= '/var/lib/one/datastores'
        FileUtils.mkdir_p @ds_location
    end

    def dss_metrics
        puts location_metrics

        Dir.chdir @ds_location

        datastores = Dir.glob('*').select do |f|
            File.directory?(f) && f.match(/^\d+$/)
        end

        datastores.each do |ds|
            dir = "#{@ds_location}/#{ds}"

            # Skip if datastore is not marked for local monitoring
            mark = "#{dir}/.monitor"

            next unless File.exist? mark

            driver = File.read mark
            driver ||= 'ssh'

            tm_script = "#{__dir__}/../../../../tm/#{driver}/monitor_ds"
            `#{tm_script} #{dir}` if File.exist? tm_script

            puts usage(dir)
        end
    end

    def location_metrics
        "DS_LOCATION_#{total(@ds_location).delete(' ')}\n"\
        "DS_LOCATION_#{used(@ds_location).delete(' ')}\n"\
        "DS_LOCATION_#{free(@ds_location).delete(' ')}"
    end

    def usage(ds_id)
        string = <<EOT
DS = [
  ID = #{ds_id},
  #{total(ds_id)},
  #{used(ds_id)},
  #{free(ds_id)}
]
EOT
        string
    end

    def used(dir)
        "USED_MB = #{metric(dir, 3)}"
    end

    def total(dir)
        "TOTAL_MB = #{metric(dir, 2)}"
    end

    def free(dir)
        "FREE_MB = #{metric(dir, 4)}"
    end

    private

    def metric(dir, column)
        metric =    `df -B1M -P #{dir} 2>/dev/null | tail -n 1 | \
                     awk '{print $#{column}}'`.chomp

        return 0 if metric.empty?

        metric
    end

end

monitor = DSMonitor.new yaml
monitor.dss_metrics
