#
# Cookbook:: _external
# Resource:: default
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

resource_name 'automate_pipeline'
default_action :create

property :name, String, name_property: true
property :cwd, String, required: true
property :target, [Symbol, String], default: :master

alias :branch :target
alias :git_branch :target

load_current_value do
  # current_value_does_not_exist! unless delivery_api(:get, 'orgs/external/projects')
end

action :create do
  change = ::JSON.parse(::File.read(::File.expand_path('../../../../../../../change.json', node['delivery_builder']['workspace'])))
  directory "#{ENV['HOME']}/.delivery"
  file "#{ENV['HOME']}/.delivery/api-tokens" do
    content "automate.cerny.cc,cerny,builder|#{change['token']}"
  end

  delivery_api(:post, 'orgs/external/projects', JSON.generate(name: new_resource.name))
  delivery_api(:post, "orgs/external/projects/#{new_resource.name}/pipelines", JSON.generate(name: new_resource.target, base: 'master'))

  execute "#{new_resource.name} :: Create git repository" do
    command <<-EOF
      git init
      git commit --allow-empty -m 'Initial Commit'
      git checkout -b #{new_resource.git_branch}
      git add .delivery
      git commit -m 'Add Automate Build Cookbook'
    EOF
    cwd new_resource.cwd
  end

  execute "#{new_resource.name} :: Create Automate Pipeline" do
    command 'delivery init --no-spinner'
    cwd new_resource.cwd
  end

  # execute "#{new_resource.name} :: Set up delivery remote" do
  #   command <<-EOF
  #     git remote add delivery ssh://builder@cerny@automate.cerny.cc:8989/cerny/external/#{new_resource.name}
  #     git checkout master
  #     git push delivery master
  #     git checkout #{new_resource.target}
  #     git push delivery #{new_resource.target}
  #   EOF
  #   cwd new_resource.cwd
  # end
end
