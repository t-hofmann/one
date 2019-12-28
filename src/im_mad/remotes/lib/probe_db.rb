#!/usr/bin/ruby

require 'sequel'
require 'yaml'

# SQlite Interface to the caching database for the status probes
class DB

    DB_PATH = "#{__dir__}/../status.db"

    def initialize(time, hypervisor)
        @hypervisor = hypervisor.downcase

        config = "#{__dir__}/../../etc/im/#{@hypervisor}-probes.d/probe_db.conf"
        @config = YAML.load_file(config)

        @db = Sequel.connect("sqlite://#{DB_PATH}")

        setup_db rescue nil
        @dataset = @db[:states]

        @stored_ids = @dataset.map(:id)

        @time = time

        clean_old
    end

    # Returns the VM status that changed compared to the DB info
    def new_status(vms, timestamp = @time)
        new_data = ''
        real_ids = []

        vms.each do |vm|
            id = vm[/ID=[0-9-]+/].split('=').last.to_i
            status = vm[/STATE=[A-Z]+/].split('=').last

            # TODO: Cache wild VMs status. Workaround -1 non unique ID
            if id == -1
                new_data << "VM=[\n#{vm}"
                next
            end

            real_ids << id

            begin
                vminfo = get(id)
                next unless vminfo[:status] != status

                update(id, status)

                new_data << "VM=[\n#{vm}"
            rescue StandardError # no match found
                did = vm[/DEPLOY_ID=[-0-9a-zA-Z_]+/].split('=').last.to_i

                insert(:id => id, :did => did, :status => status,
                       :timestamp => timestamp, :hypervisor => @hypervisor)

                new_data << "VM=[\n#{vm}"
            end
        end

        missing_vms = missing_alot(real_ids)
        new_data << report_missing(missing_vms)

        new_data
    end

    # Updates the status of an existing VM entry
    def update(id, status, time = @time)
        @dataset.where(:id => id).update(:status => status,
                                         :timestamp => time)
    end

    # Adds a new full VM entry
    # @param [Hash] row the attributes for the VM
    def insert(row)
        @dataset.insert(row)
    end

    # Deletes a VM entry that no longer exists on the host
    def delete(condition)
        @dataset.where(condition).delete
    end

    # Returns a VM information hash
    def get(id)
        @dataset.first(:id => id)
    end

    private

    # Returns the satus data string of the MISSING VMs
    def report_missing(vms)
        string = ''

        vms.each do |vm|
            string = "VM=[\n"
            string <<  "  ID=#{vm[:id]},\n"
            string <<  "  DEPLOY_ID=#{vm[:did]},\n"
            string << %(  STATE=#{vm[:status]} ]\n)
        end

        string
    end

    # Returns the vms that have been missing too_much
    def missing_alot(real_ids)
        missing = []

        missing_now = @stored_ids - real_ids

        missing_now.each do |id|
            vm = get(id)

            next unless @time - vm[:timestamp] >= @config[:time_missing]

            update(id, 'MISSING')

            missing << get(id)
        end

        missing
    end

    # Deletes VM entries prior to the current time
    def clean_old
        obsolete = @config[:obsolete] * 60 # conf in minutes
        now = Time.now.to_i

        delete((now - Sequel[:timestamp]) >= obsolete)
    end

    def setup_db
        @db.create_table :states do
            primary_key :id
            String      :did
            Integer     :timestamp
            String      :status
            String      :hypervisor
        end
    end

end
