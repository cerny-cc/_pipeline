#
# Cookbook:: _pipeline
# Resource:: cookbook_pipeline
#
# Copyright:: 2017, Nathan Cerny
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

resource_name 'cookbook_pipeline'
default_action :create

property :name, String, name_property: true
property :cwd, String, required: true
property :source, Symbol, default: :supermarket
property :opts, Hash
property :version, String, default: lazy { latest_version }
property :org, String, default: 'external'

load_current_value do
  node.run_state['_pipeline'] ||= {}
  node.run_state['_pipeline'][org] ||= delivery_api(:get, "orgs/#{org}/projects").map { |p| p['name'] }
  node.run_state['_pipeline']['status'] ||= delivery_api(:get, 'pipeline_status')

  unless node.run_state['_pipeline'].include?('cookbooks')
    node.run_state['_pipeline']['cookbooks'] = {}
    Mixlib::ShellOut.new('knife cookbook list').run_command.stdout.each_line do |line|
      node.run_state['_pipeline']['cookbooks'][line.split[0]] = line.split[1]
    end
  end

  version node.run_state['_pipeline']['cookbooks'][name] || '0.0.0'
  current_value_does_not_exist! unless node.run_state['_pipeline'][org].include?(name)
end

action :create do
  return unless validate_source

  if node.run_state['_pipeline']['status'].map { |v| "#{v['project']}-#{v['title']}" }.include?("#{new_resource.name}-update-to-#{new_resource.version}")
    Chef::Log.info "Change already in-flight to update #{new_resource.name} to #{new_resource.version}"
    return
  end

  directory "#{new_resource.cwd}/#{new_resource.name}" do
    action [:delete, :create]
    recursive true
  end

  execute "#{new_resource.name} :: Clone project from Chef Automate Workflow" do
    command "delivery clone #{new_resource.name} --no-spinner"
    cwd new_resource.cwd
    only_if { node.run_state['_pipeline'][new_resource.org].include?(new_resource.name) }
  end

  execute "#{new_resource.name} :: Create git repository" do
    command <<-EOF
      git init
      git commit --allow-empty -m 'Initial Commit'
    EOF
    cwd "#{new_resource.cwd}/#{new_resource.name}"
    not_if { node.run_state['_pipeline'][new_resource.org].include?(new_resource.name) }
  end

  build_cookbook new_resource.name do
    cwd "#{new_resource.cwd}/#{new_resource.name}"
  end

  execute "#{new_resource.name} :: Create Automate Pipeline" do
    command 'delivery init --no-spinner'
    cwd "#{new_resource.cwd}/#{new_resource.name}"
    not_if { node.run_state['_pipeline'][new_resource.org].include?(new_resource.name) }
  end

  case new_resource.source
  when :supermarket
    execute "#{new_resource.name} :: Checkout working branch" do
      command <<-EOF
        git checkout master
        git pull delivery master
        git checkout -b update-to-#{new_resource.version}
      EOF
      cwd "#{new_resource.cwd}/#{new_resource.name}"
    end

    log "#{new_resource.name} :: Get version #{new_resource.version} from Supermarket"

    tar_extract node.run_state['_pipeline']["universe_#{new_resource.opts[:uri]}"][new_resource.name][new_resource.version]['download_url'] do
      target_dir new_resource.cwd
      download_dir new_resource.cwd
    end

    # git --no-pager log origin/master..master
  end

  execute "#{new_resource.name} :: Commit Changes" do
    command <<-EOF
      git add .
      git commit -m update-to-#{new_resource.version}
    EOF
    cwd "#{new_resource.cwd}/#{new_resource.name}"
  end

  execute "#{new_resource.name} :: Submit change to Chef Automate Workflow" do
    command 'delivery review --no-spinner --no-open'
    cwd "#{new_resource.cwd}/#{new_resource.name}"
  end
end

action :delete do
  delivery_api(:delete, "orgs/#{new_resource.org}/projects/#{new_resource.name}")
end

def validate_source
  case source
  when :supermarket
    opts[:uri] ||= 'https://supermarket.chef.io/'
    node.run_state['_pipeline']["universe_#{opts[:uri]}"] ||= supermarket_api(:get, '/universe', '', {}, opts[:uri])

    unless node.run_state['_pipeline']["universe_#{opts[:uri]}"].include?(name)
      Chef::Log.error "Cookbook #{name} is not on supermarket!"
      raise unless node.run_state['_pipeline']['cookbooks'].include?(name)
    end
    true
  else
    Chef::Log.warn("Source #{source} is not currently supported by the pipeline.")
    false
  end
end

def latest_version
  validate_source
  case source
  when :supermarket
    node.run_state['_pipeline']["universe_#{opts[:uri]}"][name].keys.map { |v| Gem::Version.new(v) }.max.to_s
  else
    '0.0.0'
  end
end
