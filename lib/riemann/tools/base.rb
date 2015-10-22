module Riemann
  module Tools
    class Base
      require 'trollop'
      require 'riemann/client'
      
      def initialize(config)
        @argv = config.split
        opt :host, "Riemann host", :default => '127.0.0.1'
        opt :port, "Riemann port", :default => 5555
        opt :event_host, "Event hostname", :type => String
        opt :interval, "Seconds between updates", :default => 5
        opt :tag, "Tag to add to events", :type => String, :multi => true
        opt :ttl, "TTL for events", :type => Integer
        opt :attribute, "Attribute to add to the event", :type => String, :multi => true
        opt :timeout, "Timeout (in seconds) when waiting for acknowledgements", :default => 30
        opt :tcp, "Use TCP transport instead of UDP (improves reliability, slight overhead.", :default => true
      end
      
      def opt(*a)
        a.unshift :opt
        @opts ||= []
        @opts << a
      end

      def options_init
        p = Trollop::Parser.new
        @opts.each do |o|
          p.send *o
        end
        Trollop::with_standard_exception_handling(p) do
          parsed = p.parse @argv
          parsed
        end
      end

      # Returns parsed options (cached) from command line.
      def options
        @options ||= options_init
      end
      alias :opts :options

      def attributes
        @attributes ||= Hash[options[:attribute].map do |attr|
          k,v = attr.split(/=/)
          if k and v
            [k,v]
          end
        end]
      end

      def report(event)
        event[:ttl] ||= (options[:ttl] || (options[:interval] * 2))
        report_no_ttl(event)
      end

      def report_no_ttl(event)
        if options[:tag]
          # Work around a bug with beefcake which can't take frozen strings.
          event[:tags] = options[:tag].map(&:dup)
        end

        if options[:event_host]
          event[:host] = options[:event_host].dup
        end

        event = event.merge(attributes)

        riemann << event
      end

      def new_riemann_client
        r = Riemann::Client.new(
          :host    => options[:host],
          :port    => options[:port],
          :timeout => options[:timeout]
        )
        if options[:tcp]
          r.tcp
        else
          r
        end
      end

      def riemann
        @@riemann ||= new_riemann_client
      end
      alias :r :riemann

      def run(plugins)
        t0 = Time.now
        loop do
          plugins.each do |plugin|
            begin
              plugin.tick
            rescue => e
            $stderr.puts "#{e.class} #{e}\n#{e.backtrace.join "\n"}"
            end
          end
          # Sleep.
          sleep(options[:interval] - ((Time.now - t0) % options[:interval]))
        end
      end

      def tick
      end
    end
  end
end
