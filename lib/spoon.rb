require "spoon/version"
require 'docker'
require 'json'
require 'pp'
require 'uri'

module Spoon
  include Methadone::Main
  include Methadone::CLILogging
  include Methadone::SH
  version(Spoon::VERSION)

  main do |instance|
    parse_config(options[:config])
    D options.inspect
    if options[:list]
      instance_list
    elsif options["list-images"]
      image_list
    elsif options[:build]
      image_build
    elsif options[:destroy]
      instance_destroy(apply_prefix(options[:destroy]))
    elsif instance
      instance_connect(apply_prefix(instance), options[:command])
    else
      help_now!("You either need to provide an action or an instance to connect to")
    end

  end

  description "Create & Connect to pairing environments in Docker"

  # Actions
  on("-l", "--list", "List available spoon instances")
  on("-d", "--destroy NAME", "Destroy spoon instance with NAME")
  on("-b", "--build", "Build image from Dockerfile using name passed to --image")

  # Configurables
  options[:builddir] = '.'
  on("--builddir DIR", "Directory containing Dockerfile")
  on("--pre-build-commands", "List of commands to run locally before building image")
  options[:url] = Docker.url
  on("-u", "--url URL", "Docker url to connect to")
  on("-L", "--list-images", "List available spoon images")
  options[:image] = "spoon-pairing"
  on("-i", "--image NAME", "Use image for spoon instance")
  options[:prefix] = 'spoon-'
  on("-p", "--prefix PREFIX", "Prefix for container names")
  options[:command] = ''
  options[:config] = "#{ENV['HOME']}/.spoonrc"
  on("-c", "--config FILE", "Config file to use for spoon options")
  on("--debug", "Enable debug")

  arg(:instance, :optional, "Spoon instance to connect to")

  use_log_level_option

  def self.parse_config(config_file)
    eval(File.open(config_file).read)
  end

  def self.apply_prefix(name)
    "spoon-#{name}"
  end

  def self.remove_prefix(name)
    if name.start_with? "/"
      name[7..-1]
    else
      name[6..-1]
    end
  end

  def self.image_build
    # Run pre-build commands
    options["pre-build-commands"].each do |command|
      sh command
    end
    D "pre-build commands complete, building Docker image"

    docker_url
    build_opts = { 't' => options[:image], 'rm' => true }
    Docker::Image.build_from_dir(options[:builddir], build_opts) do |chunk|
      print_docker_response(chunk)
    end
  end

  def self.image_list
    docker_url
    Docker::Image.all.each do |image|
      next if image.info["RepoTags"] == ["<none>:<none>"]
      puts "Image: #{image.info["RepoTags"]}"
    end
  end

  def self.print_parsed_response(response)
    case response
    when Hash
      response.each do |key, value|
        case key
        when 'stream'
          puts value
        else
          puts "#{key}: #{value}"
        end
      end
    when Array
      response.each do |hash|
        print_parsed_response(hash)
      end
    end
  end

  def self.print_docker_response(json)
    print_parsed_response(JSON.parse(json))
  end

  def self.instance_connect(name, command='')
    docker_url
    if not instance_exists? name
      puts "The `#{name}` container doesn't exist, creating..."
      instance_create(name)
    end

    puts "Connecting to `#{name}`"
    instance_ssh(name, command)
  end

  def self.instance_list
    docker_url
    puts "List of available spoon containers:"
    container_list = Docker::Container.all
    container_list.each do |container|
      name = container.info["Names"].first.to_s
      if name.start_with? "/#{options[:prefix]}"
        puts remove_prefix(name)
      end
    end
  end

  def self.instance_destroy(name)
    docker_url
    container = get_container(name)

    if container
      puts "Destroying #{name}"
      begin
        container.kill
      rescue
        puts "Failed to kill container #{container.id}"
      end

      container.wait(10)

      begin
        container.delete(:force => true)
      rescue
        puts "Failed to remove container #{container.id}"
      end
      puts "Done!"
    else
      puts "No container named: #{name}"
    end
  end

  def self.instance_exists?(name)
    get_container(name)
  end

  def self.instance_ssh(name, command='')
    container = get_container(name)
    host = URI.parse(options[:url]).host
    if container
      ssh_command = "\"#{command}\"" if not command.empty?
      ssh_port = get_port('22', container)
      puts "Waiting for #{name}:#{ssh_port}..." until host_available?(host, ssh_port)
      exec("ssh -t -o StrictHostKeyChecking=no -p #{ssh_port} pairing@#{host} #{ssh_command}")
    else
      puts "No container named: #{container.inspect}"
    end
  end

  def self.get_container(name)
    docker_url
    container_list = Docker::Container.all

    container_list.each do |container|
      if container.info["Names"].first.to_s == "/#{name}"
        return container
      end
    end
    return nil
  end

  def self.instance_create(name)
    docker_url
    container = Docker::Container.create({
      'Image' => options[:image],
      'name' => name,
      'Entrypoint' => 'runit',
      'Hostname' => remove_prefix(name)
    })
    container = container.start({ 'PublishAllPorts' => true })
  end

  def self.host_available?(hostname, port)
    socket = TCPSocket.new(hostname, port)
    IO.select([socket], nil, nil, 5)
  rescue SocketError, Errno::ECONNREFUSED,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, IOError
    sleep(0.25)
    false
  rescue Errno::EPERM, Errno::ETIMEDOUT
    false
  ensure
    socket && socket.close
  end

  def self.docker_url
    Docker.url = options[:url]
  end

  def self.get_port(port, container)
    container.json['NetworkSettings']['Ports']["#{port}/tcp"].first['HostPort']
  end

  def self.D(message)
    if options[:debug]
      puts "D: #{message}"
    end
  end

  go!
end

  # option :debug, :type => :boolean, :default => true


  # private