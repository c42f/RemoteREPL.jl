# Utilities for securely tunnelling traffic from client to a remote server

# Find a free port on `network_interface`
function find_free_port(network_interface)
    # listen on port 0 => kernel chooses a free port. See, for example,
    # https://stackoverflow.com/questions/44875422/how-to-pick-a-free-port-for-a-subprocess
    server = listen(network_interface, 0)
    _, free_port = getsockname(server)
    close(server)
    # The kernel can reuse free_port here after $some_time_delay, but apprently
    # this is large enough for Selenium to have used this technique for ten
    # years...
    return free_port
end

function comm_pipeline(cmd::Cmd)
    errbuf = IOBuffer()
    proc = run(pipeline(cmd, stdout=errbuf, stderr=errbuf),
               wait=false)
    # TODO: Kill this earlier if we need to reconnect in ensure_connected!()
    atexit() do
        kill(proc)
    end
    @async begin
        # Attempt to log any connection errors to the user
        wait(proc)
        errors = String(take!(errbuf))
        if !isempty(errors) || !success(proc)
            @warn "Tunnel output" errors=Text(errors)
        end
    end
    proc
end

function ssh_tunnel(host, port, tunnel_interface, tunnel_port; ssh_opts=``)
    OpenSSH_jll.ssh() do ssh_exe
        # Tunnel binds locally to $tunnel_interface:$tunnel_port
        # The other end jumps through $host using the provided identity,
        # and forwards the data to $port on *itself* (this is the localhost:$port
        # part - "localhost" being resolved relative to $host)
        ssh_cmd = `$ssh_exe $ssh_opts -o ExitOnForwardFailure=yes -o ServerAliveInterval=60
                            -N -L $tunnel_interface:$tunnel_port:localhost:$port $host`
        @debug "Connecting SSH tunnel to remote address $host via ssh tunnel to $port" ssh_cmd
        comm_pipeline(ssh_cmd)
    end
end

function aws_tunnel(instance_id, port, tunnel_port; region=nothing)
    region = region === nothing ? `` : `--region $region`
    aws_cmd = `aws ssm start-session $region --target $instance_id --document-name AWS-StartPortForwardingSession --parameters "{\"portNumber\":[\"$port\"],\"localPortNumber\":[\"$tunnel_port\"]}"`
    @debug "Connecting AWS session manager tunnel to EC2 instance $instance_id via port $port" aws_cmd
    comm_pipeline(aws_cmd)
end

function k8s_tunnel(host, port, tunnel_port; namespace=nothing)
    namespace = namespace === nothing ? `` : `-n $namespace`
    k8s_cmd = `kubectl port-forward $namespace $host $tunnel_port:$port`
    @debug "Connecting through kubectl to resource $host via port $port" k8s_cmd
    comm_pipeline(k8s_cmd)
end

function connect_via_tunnel(host, port; retry_timeout,
        tunnel=:ssh, ssh_opts=``, region=nothing, namespace=nothing)
    # We assume the remote server is only listening for local connections.
    tunnel_interface = Sockets.localhost
    tunnel_port = find_free_port(tunnel_interface)
    comm_proc = if tunnel == :ssh
            ssh_tunnel(host, port, tunnel_interface, tunnel_port; ssh_opts=ssh_opts)
        elseif tunnel == :aws
            aws_tunnel(host, port, tunnel_port; region=region)
        elseif tunnel == :k8s
            k8s_tunnel(host, port, tunnel_port; namespace=namespace)
        end

    # Retry loop to wait for the connection.
    for i=1:retry_timeout
        try
            return connect(tunnel_interface, tunnel_port)
        catch exc
            if (exc isa Base.IOError) && process_running(comm_proc) && i < retry_timeout
                sleep(1)
            else
                kill(comm_proc)
                wait(comm_proc)
                @error "Exceeded maximum socket connection attempts"
                rethrow()
            end
        end
    end
end


