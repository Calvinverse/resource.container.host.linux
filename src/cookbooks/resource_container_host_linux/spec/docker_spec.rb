# frozen_string_literal: true

require 'spec_helper'

describe 'resource_container_host_linux::docker' do
  context 'configures docker' do
    let(:chef_run) { ChefSpec::SoloRunner.converge(described_recipe) }

    it 'installs docker' do
      expect(chef_run).to create_docker_installation_package('default').with(
        action: [:create],
        package_name: 'docker-engine',
        package_options: "--force-yes -o Dpkg::Options::='--force-confold' -o Dpkg::Options::='--force-all'",
        version: '17.05.0'
      )
    end
  end
end
