# Reports current docker container events as well as and network, CPU and
# memory used by each container to riemann.

require File.expand_path('../base.rb', __FILE__)

class Riemann::Tools::Docker < Riemann::Tools::Base
  
  require 'excon'
  require 'time'
  require 'json'
  
  START_EVENTS = ['start', 'unpause']
  STOP_EVENTS = ['oom', 'destroy', 'die', 'kill', 'pause']
  
  def initialize(argv)
    super argv
    opt :docker_address, "Docker socket", :default => "unix:///var/run/docker.sock"
    opt :checks, "A list of checks to run.", :type => :strings, :default => ['cpu', 'event', 'network', 'memory'] 
    opt :read_timeout, 'Docker requests read timeout', :type => :int, :default => 2
    opt :open_timeout, 'Docker requests open timeout', :type => :int, :default => 1
    opt :memory_warning, "Memory warning threshold (fraction of RAM)", :default => 0.85
    opt :memory_critical, "Memory critical threshold (fraction of RAM)", :default => 0.95
    opt :cpu_warning, "CPU warning threshold (fraction of total jiffies)", :default => 0.9
    opt :cpu_critical, "CPU critical threshold (fraction of total jiffies)", :default => 0.95
    opt :network_warning, "Network events considered as warning level", :type => :strings,
        :default => ["rx_dropped", "rx_errors", "tx_dropped", "tx_errors"]
    opt :network_critical, "Network events considered as warning level", :type => :strings,
        :default => []
    opt :critical_events, "Docker events considered as critical level", :type => :strings,
        :default => ['oom'] 
    opt :warning_events, "Docker events considered as warning level", :type => :strings,
        :default => ['die', 'destroy', 'kill', 'pause', 'stop']

    
    @limits = {
      :memory => {:critical => opts[:memory_critical], :warning => opts[:memory_warning]},
      :cpu => {:critical => opts[:cpu_critical], :warning => opts[:cpu_warning]},
    }
    opts[:checks].each do |check|
      case check
      when "event"
        @events_enabled = true
      when "network"
        @network_enabled = true
      when "cpu"
        @cpu_enabled = true
      when "memory"
        @memory_enabled = true
      end
    end
    @check_time = nil

    @connection = nil
    if opts[:docker_address].start_with?('unix://')
      address = opts[:docker_address].sub('unix://', '')
      @connection = Excon.new('unix:///', :socket => address, :read_timeout => opts[:read_timeout])
    else
      @connection = Excon.new(opts[:docker_address], :read_timeout => opts[:read_timeout])
    end

    @container_list = init_container_list
  end
  
  def report_failure(uri, state, description)
    report(
      :service     => "docker",
      :state       => state,
      :uri         => uri,
      :description => description,
      :tags        => ["docker"]
    )
  end

  def report_connection_error(e, uri)
    report_failure uri, "critical", "Docker remote API connection error: #{e.class} - #{e.message}" 
  end

  def check_response_status(uri, response)
    if response.status != 200
      report_failure(
        uri,
        "critical",
        "Docker remote API response error: #{response.status} - #{response.body}"
      )
      return false
    end
    true
  end
  
  def get(uri)
    response = nil
    begin
      response = @connection.request(:method => :get, :path => uri)
    rescue => e
      report_connection_error e, uri
    end
    response
  end
  
  def get_json(uri)
    res = get uri
    if !res.nil? && check_response_status(uri, res) && !res.body.empty?
      JSON.parse(res.body)
    end
  end
  
  def get_chunks(uri)
    chunks = []
    streamer = lambda{|chunk, r, t|
      chunks << chunk
    }
    begin
      response = @connection.request(:method => :get, :path => uri, :response_block => streamer)
    rescue => e
      report_connection_error(e, uri)
    end
    chunks
  end

  def get_chunk_json(uri)
    chunks = get_chunks uri
    if !chunks.nil? && !chunks.empty?
      chunks.map{|chunk|
        JSON.parse(chunk)}
    end
  end

  def get_first_chunk_json(uri)
    count = 0
    json = nil
    res = ""
    streamer = lambda{|chunk, r, t|
      res << chunk
      json = nil
      begin
        json = JSON.parse(res)
      rescue => e
        if count < 2
          count += 1
        else
          @connection.reset
        end
      else
        @connection.reset
      end
    }
    begin
      response = @connection.request(:method => :get, :path => uri, :response_block => streamer)
    rescue Excon::Errors::SocketError => e
    rescue => e
      report_connection_error(e, uri)
    end
    json
  end
  
  def container_name(id)
    uri = "/containers/#{id}/json"
    container = get_json uri
    if !container.nil?
      container["Name"]
    end
  end

  def init_container_list
    @check_time = Time.now
    uri = "/containers/json?status=running"
    containers = get_json uri
    if !containers.nil?
      c = 
      Hash[ containers.map{ |container|
        container["Id"] 
      }.map{ |id|
        name = container_name id
        unless name.nil? 
          [id, { :name => name }]
        end
      }.compact ]
    end
  end

  def remove_container(id)
    @container_list.delete(id)
  end

  def add_container(id)
    name = container_name(id)
    unless name.nil?
      @container_list[id] = { :name => name }
    end
  end

  def get_events
    last_check = @check_time
    @check_time = Time.now
    if @check_time.to_i > last_check.to_i
      uri = "/events?since=#{last_check.to_i}&until=#{@check_time.to_i-1}"
      get_chunk_json(uri)
    end
  end

  def update_container_list(events)
    events.each{ |event|
      if STOP_EVENTS.include? event["status"]
        remove_container event["id"]
      elsif START_EVENTS.include? event["status"]
        add_container event["id"]
      end
    }
  end

  def send_events(container_list, events)
    events.each{ |event|
      id = event["id"]
      name = nil
      if container_list.has_key? id
        name = container_list[id][:name]
      else
        name = container_name id
      end
      if !name.nil?
        event_status = event["status"]
        report_state = :ok
        if opts[:critical_events].include? event_status
          report_state = :critical
        elsif opts[:warning_events].include? event_status
          report_state = :warning
        end
        report_no_ttl(
          :service     => "docker.events",
          :state       => report_state.to_s,
          :container   => name,
          :description => "Docker container #{event_status} event",
          :event       => event_status,
          :image       => event["image"],
          :time        => event["time"],
          :tags        => ["docker", "container"]
        )
      end
    }
  end
  
  def send_stats(id, data)
    uri = "/containers/#{id}/stats"
    stats = get_first_chunk_json uri
    if !stats.nil?
      read_time = Time.parse(stats["read"])
      if @network_enabled
        network = stats["network"]
        if !data[:network].nil?
          send_network_stats read_time, data, network
        end
        data[:network] = network
      end
      if @memory_enabled
        send_memory_stats read_time, data, stats["memory_stats"]
      end
      if @cpu_enabled
        cpu_usage = stats["cpu_stats"]["cpu_usage"]
        system_cpu_usage = stats["cpu_stats"]["system_cpu_usage"]
        if !data[:cpu_usage].nil?
          send_cpu_stats read_time, data, cpu_usage, system_cpu_usage
        end
        data[:cpu_usage] = cpu_usage
        data[:system_cpu_usage] = system_cpu_usage
      end
    end
  end

  def get_network_emergency_level(key, value)
    if value > 0 && opts[:network_critical].include?(key)
      return :critical
    elsif value > 0 && opts[:network_warning].include?(key)
      return :warning
    end
    return :ok
  end

  def get_emergency_level(service, value)
    if value > @limits[service][:critical]
      return :critical
    elsif value > @limits[service][:warning]
      return :warning
    end
    return :ok
  end

  def send_memory_stats(read_time, data, memory)
    name = data[:name]
    usage = memory["usage"].to_f / memory["limit"]
    max_usage = memory["max_usage"].to_f / memory["limit"]
    {:usage => usage, :max_usage => max_usage}.each{|key, metric|
      report(
        :service     => "docker #{name} memory_#{key}",
        :state       => get_emergency_level(:memory, metric).to_s,
        :container   => name,
        :description => "docker container memory usage",
        :metric      => metric,
        :tags        => ["docker", "memory"],
        :time        => read_time.to_i
      )
    }
  end
  
  def send_network_stats(read_time, data, network)
    name = data[:name]
    network.each{ |key, acc|
      value = acc - data[:network][key]
      report(
        :service     => "docker #{name} network_#{key}",
        :state       => get_network_emergency_level(key, value).to_s,
        :container   => name,
        :description => "docker container network usage",
        :metric      => value,
        :tags        => ["docker", "network"],
        :time        => read_time.to_i
      )
    }
  end
  
  def send_cpu_stats(read_time, data, cpu_usage, system_cpu_usage)
    name = data[:name]
    old_cpu_usage = data[:cpu_usage]["total_usage"]
    old_system_cpu_usage = data[:system_cpu_usage]
    duration_system_cpu_usage = system_cpu_usage - old_system_cpu_usage
    fraction_cpu_usage = (cpu_usage["total_usage"] - old_cpu_usage).to_f / duration_system_cpu_usage
    percpu_usage = cpu_usage["percpu_usage"]
    old_percpu_usage = data[:cpu_usage]["percpu_usage"]
    

    fraction_percpu_usage = percpu_usage
      .zip(old_percpu_usage).
      map{|a|
        a.inject{ |new, old|
          (new - old).to_f / duration_system_cpu_usage
        }
      }  
    report(
      :service     => "docker #{name} cpu_usage",
      :state       => get_emergency_level(:cpu, fraction_cpu_usage).to_s,
      :container   => name,
      :description => "docker container cpu usage",
      :metric      => fraction_cpu_usage,
      :tags        => ["docker", "cpu"],
      :time        => read_time.to_i
    )
    fraction_percpu_usage.each.with_index{|fraction, index|
      report(
        :service     => "docker #{name} cpu_#{index}_usage",
        :state       => get_emergency_level(:cpu, fraction).to_s,
        :container   => name,
        :description => "docker container cpu usage",
        :metric      => fraction,
        :tags        => ["docker", "cpu"],
        :time        => read_time.to_i
      )
    }
  end

  def tick
    if @container_list.nil?
      return init_container_list
    end
    events = get_events
    unless events.nil? || events.empty?
      update_container_list events 
      if @events_enabled
        send_events @container_list, events 
      end
    end
    if @network_enabled || @memory_enabled || @cpu_enabled
      @container_list.each{ |id, data|
        send_stats(id, data)
      }
    end
  end
end