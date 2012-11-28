require "thor"
require "highline"
require "settingslogic"
require "fileutils"

module Bosh::Bootstrap
  class Cli < Thor
    include Thor::Actions

    attr_reader :iaas_credentials

    desc "local", "Bootstrap bosh, using local server as inception VM"
    method_option :fog, :type => :string, :desc => "fog config file (default: ~/.fog)"
    method_option :"upgrade-deps", :type => :boolean, :desc => "Force upgrade dependencies, packages & gems"
    def local
      load_options # from method_options above

      stage_1
      stage_2

      header "Skipping Stage 3: Create the Inception VM",
        :skipping => "Running in local mode instead. This is the Inception VM. POW!"

      server = Commander::LocalServer.new

      header "Stage 4: Preparing the Inception VM"
      unless server.run(Bosh::Bootstrap::Stages::StagePrepareInceptionVm.new(settings).commands)
        error "Failed to complete Stage 4: Preparing the Inception VM"
      end
      
      header "Stage 5: Deploying micro BOSH"
      unless server.run(Bosh::Bootstrap::Stages::MicroBoshDeploy.new(settings).commands)
        error "Failed to complete Stage 5: Deploying micro BOSH"
      end
    end

    desc "local", "Bootstrap bosh, using local server as inception VM"
    method_option :fog, :type => :string, :desc => "fog config file (default: ~/.fog)"
    def remote
      load_options # from method_options above

      stage_1
      stage_2
    end

    no_tasks do
      def stage_1
        if settings[:provider]
          header "Stage 1: Choose infrastructure",
            :skipping => "Already selected infrastructure provider"
        else
          header "Stage 1: Choose infrastructure"
          choose_fog_provider
        end
        confirm "Using #{settings.provider} infrastructure provider."

        unless settings[:region_code]
          choose_provider_region
        end
        if settings[:region_code]
          confirm "Using #{settings.provider} #{settings.region_code} region."
        else
          confirm "No specific region/data center for #{settings.provider}"
        end
      end
      
      def stage_2
        header "Stage 2: Configuration"
        unless settings[:bosh_username]
          prompt_for_bosh_credentials
        end
        confirm "After BOSH is created, your username will be #{settings.bosh_username}"

        # TODO provision IP address for BOSH
        ip_address      = "2.3.4.5"
        password        = settings.bosh_password # FIXME dual use of password?
        salted_password = `mkpasswd -m sha-512 '#{password}'`.strip
        settings[:bosh] = {
          "ip_address" => ip_address,
          "password" => password,
          "salted_password" => salted_password,
          "persistent_disk" => 16384
        }

        unless settings[:micro_bosh_stemcell_name]
          settings[:micro_bosh_stemcell_name] = micro_bosh_stemcell_name
          save_settings!
        end

        confirm "Micro BOSH will be created with stemcell #{settings.micro_bosh_stemcell_name}"
      end

      # Display header for a new section of the bootstrapper
      def header(title, options={})
        say "" # golden whitespace
        if skipping = options[:skipping]
          say "Skipping #{title}", :yellow
          say skipping
        else
          say title, :green
        end
        say "" # more golden whitespace
      end

      def error(message)
        say message, :red
        exit 1
      end

      def confirm(message)
        say "Confirming: #{message}", green
        say "" # bonus golden whitespace
      end

      def load_options
        settings["fog_path"] = File.expand_path(options[:fog] || "~/.fog")

        if options["upgrade-deps"]
          settings["upgrade_deps"] = options["upgrade-deps"]
        else
          settings.delete("upgrade_deps")
        end
        save_settings!
      end

      # Previously selected settings are stored in a YAML manifest
      # Protects the manifest file with user-only priveleges
      def settings
        @settings ||= begin
          FileUtils.mkdir_p(File.dirname(settings_path))
          unless File.exists?(settings_path)
            File.open(settings_path, "w") do |file|
              file << {}.to_yaml
            end
          end
          FileUtils.chmod 0600, settings_path
          Settingslogic.new(settings_path)
        end
      end

      def save_settings!
        File.open(settings_path, "w") do |file|
          raw_settings_yaml = settings.to_yaml.gsub(" !ruby/hash:Settingslogic", "")
          file << raw_settings_yaml
        end
      end

      def settings_path
        File.expand_path("~/.bosh_bootstrap/manifest.yml")
      end

      # Displays a prompt for known IaaS that are configured
      # within .fog config file.
      #
      # For example:
      #
      # 1. AWS (default)
      # 2. AWS (bosh)
      # Choose infrastructure:  1
      #
      # If .fog config only contains one provider, do not prompt.
      #
      # fog config file looks like:
      # :default:
      #   :aws_access_key_id:     PERSONAL_ACCESS_KEY
      #   :aws_secret_access_key: PERSONAL_SECRET
      # :bosh:
      #   :aws_access_key_id:     SPECIAL_IAM_ACCESS_KEY
      #   :aws_secret_access_key: SPECIAL_IAM_SECRET_KEY
      #
      # Convert this into:
      # { "AWS (default)" => {:aws_access_key_id => ...}, "AWS (bosh)" => {...} }
      #
      # Then display options to user to choose.
      #
      # Currently detects following fog providers:
      # * AWS
      #
      # At the end, settings.iaas_credentials contains the credentials for target IaaS
      # and :provider key for the IaaS name.
      #
      #   {:provider=>"AWS",
      #    :aws_access_key_id=>"PERSONAL_ACCESS_KEY",
      #    :aws_secret_access_key=>"PERSONAL_SECRET"}
      #
      # settings.provider is the provider name
      # settings.bosh_provider is the BOSH name for the provider (aws,vsphere,openstack)
      #   so as to local stemcells (see +micro_bosh_stemcell_name+)
      def choose_fog_provider
        @fog_providers = {}
        fog_config.inject({}) do |iaas_options, fog_profile|
          profile_name, profile = fog_profile
          if profile[:aws_access_key_id]
            # TODO does fog have inbuilt detection algorithm?
            @fog_providers["AWS (#{profile_name})"] = {
              "provider" => "aws",
              "aws_access_key_id" => profile[:aws_access_key_id],
              "aws_secret_access_key" => profile[:aws_secret_access_key]
            }
          end
        end
        if @fog_providers.keys.size > 1
          HighLine.new.choose do |menu|
            menu.prompt = "Choose infrastructure:  "
            @fog_providers.each do |label, credentials|
              menu.choice(label) { @iaas_credentials = credentials }
            end
          end
        else
          @iaas_credentials = @fog_providers.values.first
          if @iaas_credentials["aws_access_key_id"]
            @iaas_credentials["provider"] = "aws"
          else
            raise "implement #choose_fog_provider for #{@iaas_credentials.inspect}"
          end
        end
        settings[:iaas_credentials] = @iaas_credentials
        settings[:bosh_cloud_properties] = bosh_cloud_properties
        settings[:bosh_resources_cloud_properties] = bosh_resources_cloud_properties
        settings[:provider] = settings.iaas_credentials.provider
        settings[:bosh_provider] = settings.bosh_cloud_properties.keys.first # aws, vsphere...
        save_settings!
      end

      def bosh_cloud_properties
        case settings.iaas_credentials.provider.to_sym
        when :aws
          {
            "aws" => {
              "access_key_id" => settings.iaas_credentials.aws_access_key_id,
              "secret_access_key" => settings.iaas_credentials.aws_secret_access_key,
              # "ec2_endpoint" => ec2.REGION.amazonaws.com - see choose_aws_region
              "default_key_name" => "microbosh",
              "default_security_groups" => ["microbosh"],
              "ec2_private_key" => "/home/vcap/.ssh/microbosh.pem"
            }
          }
        else
          raise "implement #bosh_cloud_properties for #{settings.iaas_credentials.provider}"
        end
      end

      def bosh_resources_cloud_properties
        case settings.iaas_credentials.provider.to_sym
        when :aws
          {"instance_type" => "m1.medium"}
        else
          raise "implement #bosh_resources_cloud_properties for #{settings.iaas_credentials.provider}"
        end
      end

      # Ask user to provide region information (URI)
      # or choose from a known list of regions (e.g. AWS)
      # Return true if region selected (@region_code is set)
      # Else return false
      def choose_provider_region
        case settings[:provider].to_sym
        when :aws
          choose_aws_region
        else
          false
        end
      end

      def choose_aws_region
        HighLine.new.choose do |menu|
          menu.prompt = "Choose AWS region:  "
          aws_regions.each do |region|
            menu.choice(region) do
              settings[:aws_region] = region
              settings[:region_code] = region
              settings.bosh_cloud_properties.aws[:ec2_endpoint] = "ec2.#{region}.amazonaws.com"
              save_settings!
            end
          end
        end
        true
      end

      # supported by fog
      # FIXME weird that fog has no method to return this list
      def aws_regions
        ['ap-northeast-1', 'ap-southeast-1', 'eu-west-1', 'us-east-1', 'us-west-1', 'us-west-2', 'sa-east-1']
      end

      def fog_config
        @fog_config ||= begin
          unless File.exists?(fog_config_path)
            error "Please create a #{fog_config_path} fog configuration file"
          end
          say "Found infrastructure API credentials at #{fog_config_path} (override with --fog)"
          YAML.load_file(fog_config_path)
        end
      end

      def fog_config_path
        settings.fog_path
      end

      def prompt_for_bosh_credentials
        prompt = HighLine.new
        say "Please enter a user/password for the BOSH that will be created."
        settings[:bosh_username] = prompt.ask("BOSH username: ") { |q| q.default = `whoami`.strip }
        settings[:bosh_password] = prompt.ask("BOSH password: ") { |q| q.echo = "x" }
        save_settings!
      end

      # Returns the latest micro-bosh stemcell
      # for the target provider (aws, vsphere, openstack)
      def micro_bosh_stemcell_name
        @micro_bosh_stemcell_name ||= begin
          provider = settings.bosh_provider # aws, vsphere, openstack
          scope = ",stable" # latest stable micro-bosh stemcell by default
          bosh_stemcells_cmd = "bosh public stemcells --tags micro,#{provider}#{scope}"
          say "Locating micro-bosh stemcell, running '#{bosh_stemcells_cmd}'..."
          `#{bosh_stemcells_cmd} | grep micro | awk '{ print $2 }' | head -n 1`
        end
      end

      def cyan; "\033[36m" end
      def clear; "\033[0m" end
      def bold; "\033[1m" end
      def red; "\033[31m" end
      def green; "\033[32m" end
      def yellow; "\033[33m" end
    end
  end
end