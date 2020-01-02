/* -------------------------------------------------------------------------- */
/* Copyright 2002-2019, OpenNebula Project, OpenNebula Systems                */
/*                                                                            */
/* Licensed under the Apache License, Version 2.0 (the "License"); you may    */
/* not use this file except in compliance with the License. You may obtain    */
/* a copy of the License at                                                   */
/*                                                                            */
/* http://www.apache.org/licenses/LICENSE-2.0                                 */
/*                                                                            */
/* Unless required by applicable law or agreed to in writing, software        */
/* distributed under the License is distributed on an "AS IS" BASIS,          */
/* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   */
/* See the License for the specific language governing permissions and        */
/* limitations under the License.                                             */
/* -------------------------------------------------------------------------- */

#include "InformationManager.h"
#include "HostPool.h"
#include "OpenNebulaMessages.h"

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

int InformationManager::start()
{
    std::string error;

    using namespace std::placeholders; // for _1

    register_action(OpenNebulaMessages::UNDEFINED,
            &InformationManager::_undefined);

    register_action(OpenNebulaMessages::HOST_STATE,
            bind(&InformationManager::_host_state, this, _1));

    register_action(OpenNebulaMessages::SYSTEM_HOST,
            bind(&InformationManager::_system_host, this, _1));

    register_action(OpenNebulaMessages::VM_STATE,
            bind(&InformationManager::_vm_state, this, _1));

    int rc = DriverManager::start(error);

    if ( rc != 0 )
    {
        NebulaLog::error("InM", "Error starting Information Manager: " + error);
        return -1;
    }

    NebulaLog::info("InM", "Starting Information Manager...");

    im_thread = std::thread([&] {
        NebulaLog::info("InM", "Information Manager started.");

        am.loop(timer_period);

        NebulaLog::info("InM", "Information Manager stopped.");
    });

    am.trigger(ActionRequest::USER);

    return rc;
}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

void InformationManager::stop_monitor(int hid, const string& name, const string& im_mad)
{
    auto * imd = get_driver("monitord");

    if (!imd)
    {
        NebulaLog::error("InM", "Could not find information driver 'monitor'");

        return;
    }

    Template data;
    data.add("NAME", name);
    data.add("IM_MAD", im_mad);
    string tmp;

    Message<OpenNebulaMessages> msg;

    msg.type(OpenNebulaMessages::STOP_MONITOR);
    msg.oid(hid);
    msg.payload(data.to_xml(tmp));

    imd->write(msg);
}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

int InformationManager::start_monitor(Host * host, bool update_remotes)
{
    ostringstream oss;

    oss << "Monitoring host "<< host->get_name()<< " ("<< host->get_oid()<< ")";
    NebulaLog::log("InM",Log::DEBUG,oss);

    auto imd = get_driver("monitord");

    if (!imd)
    {
        host->error("Cannot find driver: 'monitor'");
        return -1;
    }

    Message<OpenNebulaMessages> msg;

    msg.type(OpenNebulaMessages::START_MONITOR);
    msg.oid(host->get_oid());
    msg.payload(to_string(update_remotes));

    imd->write(msg);

    return 0;
}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

void InformationManager::update_host(Host *host)
{
    auto imd = get_driver("monitord");

    if (!imd)
    {
        return;
    }

    string tmp;
    Message<OpenNebulaMessages> msg;

    msg.type(OpenNebulaMessages::UPDATE_HOST);
    msg.oid(host->get_oid());
    msg.payload(host->to_xml(tmp));

    imd->write(msg);
}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

void InformationManager::delete_host(int hid)
{
    auto imd = get_driver("monitord");

    if (!imd)
    {
        return;
    }

    Message<OpenNebulaMessages> msg;

    msg.type(OpenNebulaMessages::DEL_HOST);
    msg.oid(hid);

    imd->write(msg);
}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

void InformationManager::_undefined(unique_ptr<Message<OpenNebulaMessages>> msg)
{
    NebulaLog::warn("InM", "Received undefined message: " + msg->payload());
}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

void InformationManager::_host_state(unique_ptr<Message<OpenNebulaMessages>> msg)
{
    NebulaLog::debug("InM", "Received host_state message: " + msg->payload());

    string str_state = msg->payload();
    Host::HostState new_state;

    if (Host::str_to_state(str_state, new_state) != 0)
    {
        NebulaLog::warn("InM", "Unable to decode host state: " + str_state);
        return;
    }

    Host* host = hpool->get(msg->oid());

    if (host == nullptr)
    {
        return;
    }

    if (host->get_state() == Host::OFFLINE) // Should not receive any info
    {
        host->unlock();

        return;
    }

    if (host->get_state() != new_state)
    {
        host->set_state(new_state);

        hpool->update(host);
    }

    host->unlock();
}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

void InformationManager::_system_host(unique_ptr<Message<OpenNebulaMessages>> msg)
{
    NebulaLog::debug("InM", "Received SYSTEM_HOST message id: " +
            to_string(msg->oid()));

    Host* host = hpool->get(msg->oid());

    if (host == nullptr)
    {
        return;
    }

    if ( host->get_state() == Host::OFFLINE ) //Should not receive any info
    {
        host->unlock();
        return;
    }

    // -------------------------------------------------------------------------

    char *   error_msg;
    Template tmpl;

    int rc = tmpl.parse(msg->payload(), &error_msg);

    if (rc != 0)
    {
        host->error(string("Error parsing monitoring template: ") + error_msg);

        free(error_msg);

        host->unlock();
        return;
    }

    // -------------------------------------------------------------------------

    host->update_info(tmpl);

    hpool->update(host);

    host->unlock();

    NebulaLog::debug("InM", "Host " + host->get_name() + " (" +
         to_string(host->get_oid()) + ") successfully monitored.");
}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

void InformationManager::timer_action(const ActionRequest& ar)
{

}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

void InformationManager::user_action(const ActionRequest& ar)
{
    auto * imd = get_driver("monitord");
    if (!imd)
    {
        NebulaLog::error("InM", "Could not find information driver 'monitor'");

        return;
    }

    string xml_hosts;
    hpool->dump(xml_hosts, "", "", false);

    Message<OpenNebulaMessages> msg;
    msg.type(OpenNebulaMessages::HOST_LIST);
    msg.payload(xml_hosts);
    imd->write(msg);
}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

void InformationManager::_vm_state(unique_ptr<Message<OpenNebulaMessages>> msg)
{
    NebulaLog::debug("InM", "Received VM_STATE message id: " +
            to_string(msg->oid()));

    // -------------------------------------------------------------------------

    char *   error_msg;
    Template tmpl;

    int rc = tmpl.parse(msg->payload(), &error_msg);

    if (rc != 0)
    {
        NebulaLog::error("InM", string("Error parsing state vm: ") + error_msg);

        free(error_msg);

        return;
    }

    // -------------------------------------------------------------------------

    std::ostringstream oss;

    oss << tmpl;

    NebulaLog::info("DEBUG", oss.str());
}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

