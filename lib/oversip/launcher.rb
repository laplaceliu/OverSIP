module OverSIP::Launcher

  extend ::OverSIP::Logger

  READY_PIPE_TIMEOUT = 6

  @log_id = "launcher"


  def self.daemonize!(options)
    $stdin.reopen("/dev/null")

    # grandparent (launcher)  : Reads pipe, exits when master is ready.
    #  \_ parent              : Exits immediately ASAP.
    #      \_ master          : Writes to pipe when ready.

    rd, wr = IO.pipe
    grandparent = $$
    if fork
      wr.close # Grandparent does not write in the ready_pipe.
    else
      rd.close # Parent (so also future master) does not read from the ready_pipe.
      ::Process.setsid
      exit if fork # Parent dies now.
    end

    # I'm grandparent (launcher) process.
    if grandparent == $$
      # Master process will inmediatelly write in the ready_pipe its PID so we get
      # its PID.
      master_pid = nil
      begin
        ::Timeout::timeout(READY_PIPE_TIMEOUT/2) do
          master_pid = rd.gets("\n").to_i rescue nil
        end
      rescue ::Timeout::Error
        fatal "master process didn't notify its PID within #{READY_PIPE_TIMEOUT/2} seconds"
      end
      unless master_pid
        fatal "master process failed to start"
      end

      # This will block until OverSIP::Launcher.run ends succesfully (so master process
      # writes "ok" in the ready_pipe) or until the pipe is closes without writting into it
      # (so the master process has died).
      # It can also occur that master process blocks forever and never writes into the
      # ready pipe neither closes it. In this case a timeout is raised and master process
      # is killed.
      master_ok = nil
      begin
        ::Timeout::timeout(READY_PIPE_TIMEOUT/2) do
          master_ok = (rd.read(2) rescue nil)
        end
      rescue ::Timeout::Error
        begin
          ::Process.kill(:TERM, master_pid)
          10.times do |i|
            sleep 0.05
            ::Process.wait(master_pid, ::Process::WNOHANG) rescue nil
            ::Process.kill(0, master_pid) rescue break
          end
          ::Process.kill(0, master_pid)
          ::Process.kill(:KILL, master_pid) rescue nil
        rescue ::Errno::ESRCH
        end
        fatal "master process is not ready within #{READY_PIPE_TIMEOUT/2} seconds, killing it"
      end
      unless master_ok == "ok"
        fatal "master process failed to start"
      end

      # Grandparent can die now with honor.
      exit 0

      # I'm master process.
    else
      options[:ready_pipe] = wr
    end
  end


  def self.run(options)
    configuration = ::OverSIP.configuration

    # Store the master process PID.
    ::OverSIP.master_pid = $$

    begin
      # Inmediatelly write into the ready_pipe so grandparent process reads it
      # and knowns which PID we have.
      ready_pipe = options.delete(:ready_pipe)
      ready_pipe.write($$.to_s + "\n") if ready_pipe

      # I'm master process.
      if syslogger_pid = fork
        ::OverSIP.syslogger_pid = syslogger_pid
        log_system_info "starting syslogger process (PID #{syslogger_pid})..."
        ::OverSIP::Logger.load_methods

        # Load all the libraries for the master process.
        require "oversip/master_process.rb"

        ::OverSIP::TLS.module_init
        ::OverSIP::SIP.module_init
        ::OverSIP::SIP::RFC3263.module_init
        ::OverSIP::WebSocket::WsFraming.class_init
        ::OverSIP::WebSocket::WsApp.class_init

      # I'm the sysloger process.
      else
        # Close the pipe in the syslogger process.
        ready_pipe.close rescue nil
        ready_pipe = nil

        require "oversip/syslogger_process.rb"
        ::OverSIP::SysLoggerProcess.run options
        exit
      end

      ::EM.run do

        log_system_info "using Ruby #{RUBY_VERSION}p#{RUBY_PATCHLEVEL} (#{RUBY_RELEASE_DATE} revision #{RUBY_REVISION}) [#{RUBY_PLATFORM}]"
        log_system_info "using EventMachine-LE #{::EM::VERSION}"
        log_system_info "starting event reactor..."

        # DNS resolver.
        ::OverSIP::SIP::RFC3263.run

        if configuration[:sip][:sip_udp]
          # SIP UDP IPv4 server.
          if configuration[:sip][:enable_ipv4]
            ::OverSIP::SIP::Launcher.run true, :ipv4, configuration[:sip][:listen_ipv4],
                                          configuration[:sip][:listen_port], :udp
          end

          # SIP IPv6 UDP server.
          if configuration[:sip][:enable_ipv6]
            ::OverSIP::SIP::Launcher.run true, :ipv6, configuration[:sip][:listen_ipv6],
                                          configuration[:sip][:listen_port], :udp
          end
        end

        if configuration[:sip][:sip_tcp]
          # SIP IPv4 TCP server.
          if configuration[:sip][:enable_ipv4]
            ::OverSIP::SIP::Launcher.run true, :ipv4, configuration[:sip][:listen_ipv4],
                                          configuration[:sip][:listen_port], :tcp
          end

          # SIP IPv6 TCP server.
          if configuration[:sip][:enable_ipv6]
            ::OverSIP::SIP::Launcher.run true, :ipv6, configuration[:sip][:listen_ipv6],
                                          configuration[:sip][:listen_port], :tcp
          end
        end

        if configuration[:sip][:sip_tls]
          unless configuration[:sip][:use_tls_tunnel]
            # SIP IPv4 TLS server (native).
            if configuration[:sip][:enable_ipv4]
              ::OverSIP::SIP::Launcher.run true, :ipv4, configuration[:sip][:listen_ipv4],
                                            configuration[:sip][:listen_port_tls], :tls
            end

            # SIP IPv6 TLS server (native).
            if configuration[:sip][:enable_ipv6]
              ::OverSIP::SIP::Launcher.run true, :ipv6, configuration[:sip][:listen_ipv6],
                                            configuration[:sip][:listen_port_tls], :tls
            end
          else
            # SIP IPv4 TLS server (Stud).
            if configuration[:sip][:enable_ipv4]
              ::OverSIP::SIP::Launcher.run true, :ipv4, "127.0.0.1",
                                            configuration[:sip][:listen_port_tls_tunnel], :tls_tunnel,
                                            configuration[:sip][:listen_ipv4],
                                            configuration[:sip][:listen_port_tls]
              ::OverSIP::SIP::Launcher.run false, :ipv4, configuration[:sip][:listen_ipv4],
                                            configuration[:sip][:listen_port_tls], :tls

              # Spawn a Stud process.
              spawn_stud_process options,
                                 configuration[:sip][:listen_ipv4], configuration[:sip][:listen_port_tls],
                                 "127.0.0.1", configuration[:sip][:listen_port_tls_tunnel],
                                 ssl = false
            end

            # SIP IPv6 TLS server (Stud).
            if configuration[:sip][:enable_ipv6]
              ::OverSIP::SIP::Launcher.run true, :ipv6, "::1",
                                            configuration[:sip][:listen_port_tls_tunnel], :tls_tunnel,
                                            configuration[:sip][:listen_ipv6],
                                            configuration[:sip][:listen_port_tls]
              ::OverSIP::SIP::Launcher.run false, :ipv6, configuration[:sip][:listen_ipv6],
                                            configuration[:sip][:listen_port_tls], :tls

              # Spawn a Stud process.
              spawn_stud_process options,
                                 configuration[:sip][:listen_ipv6], configuration[:sip][:listen_port_tls],
                                 "::1", configuration[:sip][:listen_port_tls_tunnel],
                                 ssl = false
            end
          end
        end

        if configuration[:websocket][:sip_ws]
          # WebSocket IPv4 TCP SIP server.
          if configuration[:websocket][:enable_ipv4]
            ::OverSIP::WebSocket::Launcher.run true, :ipv4, configuration[:websocket][:listen_ipv4],
                                                      configuration[:websocket][:listen_port], :tcp,
                                                      ::OverSIP::WebSocket::WS_SIP_PROTOCOL
          end

          # WebSocket IPv6 TCP SIP server.
          if configuration[:websocket][:enable_ipv6]
            ::OverSIP::WebSocket::Launcher.run true, :ipv6, configuration[:websocket][:listen_ipv6],
                                                      configuration[:websocket][:listen_port], :tcp,
                                                      ::OverSIP::WebSocket::WS_SIP_PROTOCOL
          end
        end

        if configuration[:websocket][:sip_wss]
          unless configuration[:websocket][:use_tls_tunnel]
            # WebSocket IPv4 TLS SIP server (native).
            if configuration[:websocket][:enable_ipv4]
              ::OverSIP::WebSocket::Launcher.run true, :ipv4, configuration[:websocket][:listen_ipv4],
                                            configuration[:websocket][:listen_port_tls], :tls,
                                            ::OverSIP::WebSocket::WS_SIP_PROTOCOL
            end

            # WebSocket IPv6 TLS SIP server (native).
            if configuration[:websocket][:enable_ipv6]
              ::OverSIP::WebSocket::Launcher.run true, :ipv6, configuration[:websocket][:listen_ipv6],
                                            configuration[:websocket][:listen_port_tls], :tls,
                                            ::OverSIP::WebSocket::WS_SIP_PROTOCOL
            end
          else
            # WebSocket IPv4 TLS SIP server (Stud).
            if configuration[:websocket][:enable_ipv4]
              ::OverSIP::WebSocket::Launcher.run true, :ipv4, "127.0.0.1",
                                            configuration[:websocket][:listen_port_tls_tunnel], :tls_tunnel,
                                            ::OverSIP::WebSocket::WS_SIP_PROTOCOL,
                                            configuration[:websocket][:listen_ipv4],
                                            configuration[:websocket][:listen_port_tls]
              ::OverSIP::WebSocket::Launcher.run false, :ipv4, configuration[:websocket][:listen_ipv4],
                                            configuration[:websocket][:listen_port_tls], :tls,
                                            ::OverSIP::WebSocket::WS_SIP_PROTOCOL

              # Spawn a Stud process.
              spawn_stud_process options,
                                 configuration[:websocket][:listen_ipv4], configuration[:websocket][:listen_port_tls],
                                 "127.0.0.1", configuration[:websocket][:listen_port_tls_tunnel],
                                 ssl = true
            end

            # WebSocket IPv6 TLS SIP server (Stud).
            if configuration[:sip][:enable_ipv6]
              ::OverSIP::WebSocket::Launcher.run true, :ipv6, "::1",
                                            configuration[:websocket][:listen_port_tls_tunnel], :tls_tunnel,
                                            ::OverSIP::WebSocket::WS_SIP_PROTOCOL,
                                            configuration[:websocket][:listen_ipv6],
                                            configuration[:websocket][:listen_port_tls]
              ::OverSIP::WebSocket::Launcher.run false, :ipv6, configuration[:websocket][:listen_ipv6],
                                            configuration[:websocket][:listen_port_tls], :tls,
                                            ::OverSIP::WebSocket::WS_SIP_PROTOCOL

              # Spawn a Stud process.
              spawn_stud_process options,
                                 configuration[:websocket][:listen_ipv6], configuration[:websocket][:listen_port_tls],
                                 "::1", configuration[:websocket][:listen_port_tls_tunnel],
                                 ssl = true
            end
          end
        end


        # TEST: WebSocket Autobahn server.
        #if configuration[:websocket][:sip_ws]
        #  if configuration[:websocket][:enable_ipv4]
        #    ::OverSIP::WebSocket::Launcher.run true, :ipv4, configuration[:websocket][:listen_ipv4],
        #                                        9001, :tcp,
        #                                        ::OverSIP::WebSocket::WS_AUTOBAHN_PROTOCOL
        #  end
        #end
        #
        #if configuration[:websocket][:sip_wss]
        #  if configuration[:websocket][:enable_ipv4]
        #    ::OverSIP::WebSocket::Launcher.run true, :ipv4, configuration[:websocket][:listen_ipv4],
        #                                        9002, :tls,
        #                                        ::OverSIP::WebSocket::WS_AUTOBAHN_PROTOCOL
        #  end
        #end


        # Change process permissions if requested.
        set_user_group(options[:user], options[:group])

        # Create PID file.
        create_pid_file(options[:pid_file])

        log_system_info "reactor running"
        log_system_info "master process (PID #{$$}) ready"
        log_system_info "#{::OverSIP::PROGRAM_NAME} #{::OverSIP::VERSION} running in background"

        # Write "ok" into the ready_pipe so grandparent process (launcher)
        # exits with status 0.
        if ready_pipe
          ready_pipe.write("ok")
          ready_pipe.close rescue nil
          ready_pipe = nil
        end

        # Stop writting into standard output/error.
        $stdout.reopen("/dev/null")
        $stderr.reopen("/dev/null")
        ::OverSIP.daemonized = true

        ::OverSIP::Logger.load_methods

        ::EM.error_handler do |e|
          log_system_error "error raised during event loop and rescued by EM.error_handler:"
          log_system_error e
        end

        trap_signals

      end  # ::EM.run

    rescue => e
      fatal e
    end

  end # def self.run


  def self.create_pid_file(path)
    # Check that the PID file is accesible.
    begin
      assert_file_is_writable_readable_deletable(path)
    rescue ::OverSIP::Error => e
      fatal "cannot create PID file: #{e.message}"
    end
    # If the PID file exists (it shouldn't) check if it's stale.
    if wpid = valid_pid?(path) and wpid != $$
      fatal "already running on PID #{wpid} (or '#{path}' is stale)"
    end
    # Delete the PID file if it exists.
    ::File.unlink(path) rescue nil
    # Create the PID file.
    ::File.open(path, "w", 0644) do |f|
      f.syswrite("#$$\n")
    end
    ::OverSIP.pid_file = path
  end


  def self.assert_file_is_writable_readable_deletable(path)
    # File already exists.
    if ::File.exist?(path)
      if not ::File.file?(path)
        raise ::OverSIP::Error, "'#{path}' exits and is not a regular file"
      elsif not ::File.readable?(path)
        raise ::OverSIP::Error, "'#{path}' is not readable"
      elsif not ::File.writable?(path)
        raise ::OverSIP::Error, "'#{path}' is not writable"
      end
    end
    # Check if the parent directory is writeable.
    if not ::File.writable? ::File.dirname(path)
      raise ::OverSIP::Error, "directory '#{::File.dirname(path)}' is not writable"
    end
  end


  # Returns a PID if a given path contains a non-stale PID file,
  # false otherwise.
  def self.valid_pid?(path)
    begin
      wpid = ::File.read(path).to_i
      wpid <= 0 and return false
      # If the process exists return its PID.
      ::Process.kill(0, wpid)
      return wpid
    # If the process exists but we don't have permissions over it, return its PID.
    rescue ::Errno::EPERM
      return wpid
    # If the PID file (path) doesn't exist or the process is not running return false.
    rescue ::Errno::ENOENT, ::Errno::ESRCH
      return false
    end
  end


  def self.trap_signals
    # This should never occur, but maybe if I've missed trapping a signal.
    at_exit do
      log_system_crit "exiting due to an unknown cause ($! = #{$!.inspect})..."
      terminate
    end

    # Signals that cause OverSIP to terminate.
    exit_signals = [:TERM, :QUIT]
    exit_signals.each do |signal|
      trap signal do
        log_system_notice "#{signal} signal received, exiting..."
        terminate
      end
    end

    # Signals that must be ignored.
    ignore_signals = [:ALRM, :INT, :PIPE, :POLL, :PROF, :USR1, :USR2, :VTALRM, :WINCH]
    ignore_signals.each do |signal|
      begin
        trap signal do
          log_system_notice "#{signal.to_s.upcase} signal received, ignored"
        end
      rescue ::ArgumentError
        log_system_notice "cannot trap signal #{signal.to_s.upcase}, it could not exist in this system, ignoring it"
      end
    end

    # Signal HUP reloads logic.
    # TODO: Reload proxies (so purge DNS cache in all of them), reload websocket policy.
    trap :HUP do
      log_system_info "HUP signal received, reloading logic..."
      ::OverSIP::Config.reload_logic
    end

    # Signal CHLD is sent by syslogger process if it dies.
    trap :CHLD do
      # TODO: This won't be logged since syslogger process has died!
      log_system_crit "CHLD signal received, syslogger process could be death"
    end
  end

  def self.terminate error=false
    unless error
      log_system_info "exiting, thank you for tasting #{::OverSIP::PROGRAM_NAME}"
    end

    # Wait a bit so pending log messages in the Posix MQ can be queued.
    sleep 0.05
    delete_pid_file
    ::OverSIP::Logger.close
    kill_syslogger_process

    # Kill Stud processes.
    pid = Process.spawn "killall oversip_stud 2>/dev/null"
    Process.wait(pid)

    # Exit by preventing any exception.
    exit!( error ? false : true )
  end


  def self.delete_pid_file
    return false  unless ::OverSIP.master_pid

    ::File.delete(::OverSIP.pid_file) rescue nil
  end


  def self.kill_syslogger_process
    return false  unless ::OverSIP.master_pid

    begin
      ::Process.kill(:TERM, ::OverSIP.syslogger_pid)
      10.times do |i|
        sleep 0.05
        ::Process.wait(::OverSIP.syslogger_pid, ::Process::WNOHANG) rescue nil
        ::Process.kill(0, ::OverSIP.syslogger_pid) rescue break
      end
      ::Process.kill(0, ::OverSIP.syslogger_pid)
      ::Process.kill(:KILL, ::OverSIP.syslogger_pid) rescue nil
    rescue ::Errno::ESRCH
    end
  end


  def self.set_user_group(user, group)
    uid = ::Etc.getpwnam(user).uid  if user
    gid = ::Etc.getgrnam(group).gid  if group
    if uid or gid
      if gid && ::Process.egid != gid
        ::Process.initgroups(user, gid)  if user
        ::Process::GID.change_privilege(gid)
      end
      if uid
        ::Process.euid != uid and ::Process::UID.change_privilege(uid)
      end
    end
  end


  def self.spawn_stud_process(options, listen_ip, listen_port, bg_ip, bg_port, ssl=false)
    stud_user_group = ""
    stud_user_group << "-u #{options[:user]}" if options[:user]
    stud_user_group << " -g #{options[:group]}" if options[:group]
    ssl_option = ( ssl ? "--ssl" : "" )

    bin_dir = ::File.join(::File.absolute_path(::File.dirname(__FILE__)), "../../bin/")
    Dir.chdir(bin_dir) do
      pid = POSIX::Spawn.spawn "./oversip_stud #{stud_user_group} #{ssl_option} -f '#{listen_ip},#{listen_port}' -b '#{bg_ip},#{bg_port}' -n 2 -s --daemon --write-proxy #{::OverSIP.configuration[:tls][:full_cert]}"
      Process.waitpid(pid)
    end
  end

end