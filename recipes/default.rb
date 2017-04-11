#
# Cookbook:: _external
# Recipe:: default
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

return unless workflow_phase.eql?('syntax')

DeliverySugar::ChefServer.new(delivery_knife_rb).with_server_config do
  db = 'external_pipeline'
  dbi = 'cookbooks'
  branch = 'cerny'

  cookbook_directory = File.join(node['delivery']['workspace']['cache'], 'supermarket')

  chef_data_bag(db) do
    action :nothing
  end.run_action(:create)

  chef_data_bag_item("#{db}/#{dbi}") do
    action :nothing
    complete false
  end.run_action(:create)

  external = data_bag_item(db, dbi)
  projects = delivery_api(:get, 'orgs/external/projects')
  universe = supermarket_api(:get, '/universe')

  directory "#{cookbook_directory}/.delivery" do
    recursive true
  end

  file "#{cookbook_directory}/.delivery/cli.toml" do
    content <<-EOF
      api_protocol = "https"
      enterprise = "cerny"
      git_port = "8989"
      organization = "external"
      pipeline = "#{branch}"
      server = "automate.cerny.cc"
      user = "builder"
    EOF
  end

  external.each do |cb, ver|
    if !universe.include?(cb)
      Chef::Log.info("#{cb}-#{ver} :: Cookbook does not exist on Supermarket!")
    else
      sver = universe[cb].keys.map { |v| Gem::Version.new(v) }.max
      if sver > Gem::Version.new(ver)
        Chef::Log.info("#{cb}-#{ver} :: Version #{sver} available on Supermarket!")

        directory "#{cookbook_directory}/#{cb}" do
          action [:delete, :create]
          recursive true
        end

        execute "#{cb} :: Clone project from Chef Automate Workflow" do
          command "delivery clone #{cb} --no-spinner"
          cwd cookbook_directory
          only_if { projects.map { |p| p['name'] }.include?(cb) }
        end

        build_cookbook cb do
          action :create
          cwd "#{cookbook_directory}/#{cb}"
          git_branch branch
        end

        automate_pipeline cb do
          action :create
          cwd "#{cookbook_directory}/#{cb}"
          target branch
          not_if { projects.map { |p| p['name'] }.include?(cb) }
        end

        execute "#{cb} :: Checkout working branch" do
          command <<-EOF
            git checkout #{branch}
            git pull delivery #{branch}
            git checkout -b update-to-#{sver}
          EOF
          cwd "#{cookbook_directory}/#{cb}"
        end

        log "#{cb} :: Get version #{sver} from Supermarket"

        tar_extract universe[cb][sver.to_s]['download_url'] do
          target_dir cookbook_directory
        end

        execute "#{cb} :: Commit Changes" do
          command <<-EOF
            git add .
            git commit -m update-to-#{sver}
          EOF
          cwd "#{cookbook_directory}/#{cb}"
        end

        execute "#{cb} :: Submit change to Chef Automate Workflow" do
          command 'delivery review --no-spinner --no-open'
          cwd "#{cookbook_directory}/#{cb}"
        end

        external[cb] = sver
      else
        Chef::Log.info("#{cb}-#{ver} :: Cookbook is the latest.  No action necessary.")
      end
    end
  end
  external.save
end
