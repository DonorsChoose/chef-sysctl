# Cookbook Name:: sysctl
# Provider:: sysctl
# Author:: Jesse Nelson <spheromak@gmail.com>
#
# Copyright 2011, Jesse Nelson
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require "chef/mixin/command.rb"
include Chef::Mixin::Command

def initialize(*args)
  super
  status, output, error_message = output_of_command("which sysctl", {})
  unless status.exitstatus == 0
    Chef::Log.info "Failed to locate sysctl on this system: STDERR: #{error_message}"
    Command.handle_command_failures(status, "STDOUT: #{output}\nSTDERR: #{error_message}")
  end

  @sysctl = output.chomp
end

# sysctl -n -e  only works on linux  (-e at least is missing on mac)
# side effect is that these calls will always try to set/write on other platforms.
# This is ok for now, but prob need to do detection at some point.
# TODO: Make this work on other platforms better
def load_current_resource
  # quick & dirty os detection
  @sysctl_args = case node.os
  when "GNU/Linux","Linux","linux"
    "-n -e"
  else
    "-n"
  end

  # clean up value whitespace when its a string
  @new_resource.value.strip!  if @new_resource.value.class == String

  # find current value
  status, @current_value, error_message = output_of_command(
      "#{@sysctl} #{@sysctl_args} #{@new_resource.name}", {:ignore_failure => true})

end

# save to node obj if we were asked to
def save_to_node
  node.set[:sysctl]["#{@new_resource.name}"]  = @new_resource.value if @new_resource.save == true
end

# ensure running state
action :set do
  # heavy handed type enforcement only wnat to write if they are different  ignore inner whitespace
  if @current_value.to_s.strip.split != @new_resource.value.to_s.strip.split
    # run it
    run_command( { :command => "#{@sysctl} #{@sysctl_args} -w #{@new_resource.name}='#{@new_resource.value}'" }  )
    save_to_node
    # let chef know its done
    @new_resource.updated_by_last_action  true
  end
end


# write out a config file
action :write do

  entries = "#\n# content managed by chef local changes will be overwritten\n#\n"
  r = Hash.new 

  # walk & gather on the collecton
  run_context.resource_collection.each do |resource|
    if resource.is_a? Chef::Resource::Sysctl
      # using a hash to ensure uniqueness. We want to make sure that
      # dupes always take the last called setting. Enabling multipe redefines
      # but only resolving to a single setting in the config
      # NOTE: I am assuming the collection is in order seen.
      r[resource.name] = "#{resource.value}\n" if resource.action.include?(:write)
      resource.updated_by_last_action true # kinda a cludge, but oh well 
    end
  end
  
  # flatten entries
  entries << r.sort.map { |k,v| "#{k}=#{v}" }.join

  # So that we can refer to these within the sub-run-context block.
  cached_new_resource = new_resource

  # Setup a sub-run-context to avoid spurious warnings about
  # "Cloning resource attributes for file[/etc/sysctl.conf] from prior resource (CHEF-3694)"
  # which just means the file resource name is duplicated in the run_context.
  sub_run_context = @run_context.dup
  sub_run_context.resource_collection = Chef::ResourceCollection.new

  # Declare sub-resources within the sub-run-context. Since they are declared here,
  # they do not pollute the parent run-context.
  begin
    original_run_context, @run_context = @run_context, sub_run_context

    @config  = file node[:sysctl_file] do
      action :nothing
      owner "root"
      group "root"
      mode "0644"
      notifies :send_notification, new_resource, :immediately
    end

    # put the flattened entries in the config file
    @config.content entries

    # tell the config to build itself later
    @new_resource.notifies :create, @run_context.resource_collection.find(:file => node[:sysctl_file])

  ensure
    @run_context = original_run_context
  end

  save_to_node
end

action :send_notification do
  # Executed from the @config subresource after the :create action updates.
  # The timestamp in the file system seems to show that a single write happens,
  # no matter how many sysctl resources exist and/or have changing values.
  # However, if any sysctl resource does change, every one of them will
  # fire this updated_by_last_action notification regardless of change.
  # Presumably this is an artifact of the chef run anatomy, since each
  # resources uses the entice run_context.resource_collection to assemble
  # its @config.content entries, but the file comparision and/or writing
  # due to the :create message happens later/repeatedly. 
  @new_resource.updated_by_last_action(true)
end
