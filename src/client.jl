using ReplMaker
using REPL
using Serialization
using Sockets

struct RemoteException <: Exception
    msg::String
end

function Base.showerror(io::IO, e::RemoteException)
    # Here, we presume that e.msg is fully formatted.
    indented_msg = join("  " .* split(e.msg, '\n'), '\n')
    print(io, "RemoteException:\n", indented_msg)
end

# Super dumb macro expander which expands calls to only a single macro
# `macro_name` which is implemented as `func` taking the expressions passed to
# the macro. Complexities which are ignored:
#   * Hygiene / scoping - all symbols are non-hygenic
#   * Nesting of macro expansions - `macro_name` is expanded first regardless
#     of how it's nested within other macros in the source.
function simple_macro_expand!(func, ex, macro_name)
    if Meta.isexpr(ex, :macrocall) && ex.args[1] == macro_name
        return func(ex.args[3:end]...)
    elseif Meta.isexpr(ex, (:quote, :inert, :meta))
        # pass
    elseif ex isa Expr
        map!(ex.args, ex.args) do x
            simple_macro_expand!(func, x, macro_name)
        end
    end
    return ex
end

# Parse all top level code from `path`, using a file:// URI as the file name.
function parseall_with_file_urls(path)
    path = abspath(path)
    text = read(path, String)
    # Some rough heuristics to construct a file URI. This gives us
    # a place to put the host name.
    if !startswith(path, '/')
        path = '/'*path
    end
    if Sys.iswindows()
        path = replace(path, '\\'=>'/')
    end
    path_uri = "file://$(gethostname())$path"
    return VERSION >= v"1.6" ?
        Meta.parseall(text, filename=path_uri) :
        Base.parse_input_line(text, filename=path_uri)
end

# Replace simple occurances of `include(path)` at top level and module scope
# when `path` is a string literal.
function replace_includes!(ex, parentdir)
    if Meta.isexpr(ex, :call) && ex.args[1] == :include
        if length(ex.args) == 2 && ex.args[2] isa AbstractString
            p = joinpath(parentdir, ex.args[2])
            inc_ex = parseall_with_file_urls(p)
            replace_includes!(inc_ex, dirname(p))
            return inc_ex
        else
            error("Path in expression `$ex` must be a literal string to work with `%include`")
        end
    elseif Meta.isexpr(ex, :toplevel)
        map!(e->replace_includes!(e, parentdir), ex.args, ex.args)
    elseif Meta.isexpr(ex, :module)
        map!(e->replace_includes!(e, parentdir), ex.args[3].args, ex.args[3].args)
    end
    return ex
end

# Parse the code in `path` and recursively replace occurances of
# `include(path)` with the parsed code from that path.
function parse_and_replace_includes(path)
    path = abspath(path)
    ex = replace_includes!(parseall_with_file_urls(path), dirname(path))
end

# Read and verify header bytes on initializing the connection
function verify_header(io, ser_version=Serialization.ser_version)
    magic = String(read(io, length(PROTOCOL_MAGIC)))
    if magic != PROTOCOL_MAGIC
        if !isopen(io)
            error("RemoteREPL stream was closed while reading header")
        else
            error("RemoteREPL protocol magic number mismatch: $(repr(magic)) != $(repr(PROTOCOL_MAGIC))")
        end
    end
    version = read(io, typeof(PROTOCOL_VERSION))
    if version != PROTOCOL_VERSION
        error("RemoteREPL protocol version number mismatch: $version != $PROTOCOL_VERSION")
    end
    # Version 1: We rely on the standard Serialization library for simplicity;
    # that's backward but not forward compatible depending on
    # Serialization.ser_version, so we check for an exact match
    remote_ser_version = read(io, UInt32)
    if remote_ser_version != ser_version
        error("""
              RemoteREPL Julia Serialization format version mismatch: $remote_ser_version != $ser_version
              Try using the same version of Julia on the server and client.
              """)
    end
    return true
end

#-------------------------------------------------------------------------------
# Client side connection / session handling
mutable struct Connection
    host::Union{AbstractString,Sockets.IPAddr}
    port::Int
    tunnel::Symbol
    ssh_opts::Cmd
    region::Union{AbstractString,Nothing}
    namespace::Union{AbstractString,Nothing}
    socket::Union{IO,Nothing}
    in_module::Symbol
end

function Connection(; host::Union{AbstractString,Sockets.IPAddr}=Sockets.localhost,
                    port::Integer=DEFAULT_PORT,
                    tunnel::Symbol=host!=Sockets.localhost ? :ssh : :none,
                    ssh_opts::Cmd=``,
                    region=nothing,
                    namespace=nothing,
                    in_module::Symbol=:Main)
    conn = Connection(host, port, tunnel, ssh_opts, region, namespace, nothing, in_module)
    setup_connection!(conn)
    finalizer(close, conn)
end

Base.isopen(conn::Connection) = !isnothing(conn.socket) && isopen(conn.socket)

function setup_connection!(conn::Connection)
    socket = if conn.tunnel == :none
        connect(conn.host, conn.port)
    else
        connect_via_tunnel(conn.host, conn.port; retry_timeout=5,
            tunnel=conn.tunnel, ssh_opts=conn.ssh_opts, region=conn.region,
            namespace=conn.namespace)
    end
    Sockets.nagle(socket, false)  # Disables nagles algorithm. Appropriate for interactive connections.
    try
        verify_header(socket)
    catch exc
        close(socket)
        rethrow()
    end
    conn.socket = socket
    if conn.in_module != :Main
        send_and_receive(conn, (:in_module, conn.in_module))
    end
    conn
end

function ensure_connected!(conn)
    if !isopen(conn)
        @info "Connection dropped, attempting reconnect"
        setup_connection!(conn)
    end
end

function Base.close(conn::Connection)
    try
        if !isnothing(conn.socket) && isopen(conn.socket)
            serialize(conn.socket, (:exit,nothing))
            close(conn.socket)
        end
    finally
        conn.socket = nothing
    end
end

function ensure_connected!(f::Function, conn::Connection; retries=1)
    n_try = 1
    while true
        try
            ensure_connected!(conn)
            return f()
        catch exc
            if exc isa RemoteException
                # This is an expected error - do not retry
                rethrow()
            end
            try
                close(conn)
            catch
                exc isa Base.IOError || rethrow()
            end
            if n_try == retries+1
                @error "Network or internal error running remote repl" exception=exc,catch_backtrace()
                return nothing
            end
            n_try += 1
        end
    end
end

function send_and_receive(conn::Connection, request; read_response=true)
    serialize(conn.socket, request)
    flush(conn.socket)
    if !read_response
        return (:nothing, nothing)
    end
    max_tries = 3
    for i = 1:max_tries
        try
            return deserialize(conn.socket)
        catch exc
            # If an InterruptException is caught here while waiting for a
            # response from the server, we assume the user was trying to
            # interrupt the remote evaluation.
            #
            # This isn't perfect. For example, for large messages the user
            # might interrupt the deserialization while waiting on socket IO,
            # and corrupt the stream. However, there's not much we can do about
            # this without improving the Julia runtime.
            if exc isa InterruptException
                if i < max_tries
                    send_interrupt(conn)
                    continue
                else
                    close(conn)
                    return (:error, "ERROR: Failed to interrupt server, connection closed!")
                end
            end
            rethrow()
        end
    end
end

function send_interrupt(conn::Connection)
    serialize(conn.socket, (:interrupt, nothing))
end

#-------------------------------------------------------------------------------
# REPL integration
function parse_input(str)
    Base.parse_input_line(str)
end

function match_magic_syntax(str)
    m = match(r"^(%module|\?|%include) *(.*)", str)
    if !isnothing(m)
        return (m[1], m[2])
    else
        return nothing
    end
end

function valid_input_checker(prompt_state)
    cmdstr = String(take!(copy(REPL.LineEdit.buffer(prompt_state))))
    magic = match_magic_syntax(cmdstr)
    if !isnothing(magic)
        if magic[1] in ("%module", "?")
            cmdstr = magic[2]
        elseif magic[1] == "%include"
            return true
        end
    end
    ex = parse_input(cmdstr)
    return !Meta.isexpr(ex, :incomplete)
end

struct RemoteCompletionProvider <: REPL.LineEdit.CompletionProvider
    connection
end

function path_str(path_completion)
    path = REPL.REPLCompletions.completion_text(path_completion)
    if Sys.iswindows()
        # On windows, REPLCompletions.complete_path() adds extra escapes for
        # use within a normal string in the Juila REPL but we don't need those.
        path = replace(path, "\\\\"=>'\\')
    end
    return path
end

function REPL.complete_line(provider::RemoteCompletionProvider,
                            state::REPL.LineEdit.PromptState)::
                            Tuple{Vector{String},String,Bool}
    # See REPL.jl complete_line(c::REPLCompletionProvider, s::PromptState)
    partial = REPL.beforecursor(state.input_buffer)
    full = REPL.LineEdit.input_string(state)
    if startswith(full, "%m")
        if startswith("%module", full)
            return (["%module "], full, true)
        end
    elseif startswith(full, "%i")
        if startswith("%include", full)
            return (["%include "], full, true)
        elseif startswith(full, "%include ")
            _, path_prefix = match_magic_syntax(full)
            (path_completions, range, should_complete) =
                REPL.REPLCompletions.complete_path(path_prefix, length(path_prefix))
            completions = [path_str(c) for c in path_completions]
            return (completions, path_prefix[range], should_complete)
        end
    end
    result = ensure_connected!(provider.connection) do
        send_and_receive(provider.connection, (:repl_completion, (partial, full)))
    end
    if isnothing(result) || result[1] != :completion_result
        return ([], "", false)
    end
    return result[2]
end

function run_remote_repl_command(conn, out_stream, cmdstr)
    # Compute command
    magic = match_magic_syntax(cmdstr)
    if isnothing(magic)
        # Normal remote evaluation
        ex = parse_input(cmdstr)

        ex = simple_macro_expand!(ex, Symbol("@remote")) do clientside_ex
            try
                x = Main.eval(clientside_ex)
                if x === Base.stdout
                    # The local stdout cannot be serialized in any sensible way,
                    # but we store a placeholder for it which will be transformed
                    # into a serverside approximation of the client stream.
                    return STDOUT_PLACEHOLDER
                else
                    # Any expressions wrapped in `@remote` need to be executed
                    # on the client and wrapped in a QuoteNode to prevent them
                    # being eval'd again in the expression on the server side.
                    QuoteNode(x)
                end
            catch _
                error("Error while evaluating `@remote($clientside_ex)` before passing to the server")
            end
        end

        cmd = (:eval, ex)
    else
        # Magic prefixes
        if magic[1] == "?"
            # Help mode
            cmd = (:help, magic[2])
        elseif magic[1] == "%module"
            mod_ex = Meta.parse(magic[2])
            cmd = (:in_module, mod_ex)
        elseif magic[1] == "%include"
            cmd = (:eval, parse_and_replace_includes(magic[2]))
        end
    end

    messageid, value = ensure_connected!(conn) do
        # Set terminal properties for formatting result
        display_props = Dict(
            :displaysize=>displaysize(out_stream),
            :color=>get(out_stream, :color, false),
            :limit=>true
        )
        # TODO breaking change - send these as part of :eval, perhaps ?
        send_and_receive(conn, (:display_properties, display_props), read_response=false)

        send_and_receive(conn, cmd)
    end

    result_for_display = nothing
    if messageid in (:in_module, :eval_result, :help_result, :error)
        if !isnothing(value)
            if messageid != :eval_result || !REPL.ends_with_semicolon(cmdstr)
                result_for_display = Text(value)
            end
        end
        if messageid == :in_module
            conn.in_module = mod_ex
        end
    else
        @error "Unexpected response from server" messageid
    end
    return result_for_display
end

remote_eval_and_fetch(::Nothing, ex) = error("No remote connection is active")

function remote_eval_and_fetch(conn::Connection, ex)
    ensure_connected!(conn) do
        cmd = (:eval_and_get, ex)
        messageid, value = send_and_receive(conn, cmd)
        if messageid == :eval_and_get_result
            logstring = value[2]
            if !isempty(logstring)
                # TODO: Improve this with an async remote logger
                @info Text("Remote logs\n" * logstring)
            end
            return value[1]
        elseif messageid == :error
            throw(RemoteException(value))
        else
            error("Unexpected response message id $messageid from server")
        end
    end
end

function repl_prompt_text(conn::Connection)
    host = conn.host == Sockets.localhost ? "localhost" : conn.host
    port = conn.port == DEFAULT_PORT ? "" : ":$(conn.port)"
    disconnected = isopen(conn) ? "" : " [disconnected]"
    return "julia@$host$port$disconnected> "
end

#-------------------------------------------------------------------------------
# Public client APIs

# Connection which is currently attached to the REPL mode.
_repl_client_connection = nothing

"""
    connect_repl([host=localhost,] port::Integer=$DEFAULT_PORT;
                 use_ssh_tunnel = (host != localhost) ? :ssh : :none,
                 ssh_opts = ``, repl=Base.active_repl)

Connect client REPL to a remote `host` on `port`. This is then accessible as a
remote sub-repl of the current Julia session.

For security, `connect_repl()` uses an ssh tunnel for remote hosts. This means
that `host` needs to be running an ssh server and you need ssh credentials set
up for use on that host. For secure networks this can be disabled by setting
`tunnel=:none`.

To provide extra options to SSH, you may pass a `Cmd` object in the `ssh_opts`
keyword, for example an identity file may be set with ```ssh_opts = `-i
/path/to/identity.pem` ```. For a more permanent solution, add a `Host` section
to your ssh config file.

You can also use the following technologies for tunneling in place of SSH:
1) AWS Session Manager: set `tunnel=:aws`. The optional `region` keyword
   argument can be used to specify the AWS Region of your server.
2) kubectl: set `tunnel=:k8s`. The optional `namespace` keyword argument can be
   used to specify the namespace of your Kubernetes resource.

See README.md for more information.
"""
function connect_repl(host=Sockets.localhost, port::Integer=DEFAULT_PORT;
                      tunnel::Symbol = host!=Sockets.localhost ? :ssh : :none,
                      ssh_opts::Cmd=``,
                      region::Union{AbstractString,Nothing}=nothing,
                      namespace::Union{AbstractString,Nothing}=nothing,
                      startup_text::Bool=true,
                      repl=Base.active_repl)

    conn = connect_remote(host, port; tunnel, ssh_opts, region,namespace)
    out_stream = stdout
    prompt = ReplMaker.initrepl(c->run_remote_repl_command(conn, out_stream, c),
                       repl         = Base.active_repl,
                       valid_input_checker = valid_input_checker,
                       prompt_text  = ()->repl_prompt_text(conn),
                       prompt_color = :magenta,
                       start_key    = '>',
                       sticky_mode  = true,
                       mode_name    = "remote_repl",
                       completion_provider = RemoteCompletionProvider(conn),
                       startup_text = startup_text
                       )
    prompt
end

connect_repl(port::Integer) = connect_repl(Sockets.localhost, port)

"""
    connect_remote([host=localhost,] port::Integer=$DEFAULT_PORT;
                 tunnel = (host != localhost) ? :ssh : :none,
                 ssh_opts = ``)

Connect to remote server without any REPL integrations. This will allow you to use `@remote`, but not the REPL mode.
Useful in circumstances where no REPL is available, but interactivity is desired like Jupyter or Pluto notebooks.
Otherwise, see `connect_repl`.
"""
function connect_remote(host=Sockets.localhost, port::Integer=DEFAULT_PORT;
                        tunnel::Symbol = host!=Sockets.localhost ? :ssh : :none,
                        ssh_opts::Cmd=``,
                        region::Union{AbstractString,Nothing}=nothing,
                        namespace::Union{AbstractString,Nothing}=nothing)

    global _repl_client_connection

    if !isnothing(_repl_client_connection)
        try
            close(_repl_client_connection)
        catch exc
            @warn "Exception closing connection" exception=(exc,catch_backtrace())
        end
    end
    conn = RemoteREPL.Connection(host=host, port=port, tunnel=tunnel,
                                 ssh_opts=ssh_opts, region=region, namespace=namespace)

    # Record the connection in a global variable so it's accessible to REPL and `@remote`
    _repl_client_connection = conn
end                       


"""
    @remote ex

Execute expression `ex` on the other side of the current RemoteREPL connection
and return the value.

This can be used in both directions:
1. From the normal `julia>` prompt, execute `ex` on the remote server and
   return the value to the client.
2. From a remote prompt, execute `ex` on the *client* and push the
   resulting value to the remote server.

# Examples

Push a value from the client to the server:

```
julia> client_val = 1:100;

julia@localhost> server_val = @remote client_val
1:100
```

Fetch a pair of variables `(x,y)` from the server, and plot them on the client
with a single line:
```
# In two lines
julia> x,y = @remote (x, y)
       plot(x, y)

# Or as a single expression
julia> plot(@remote((x, y))...)
```
"""
macro remote(ex)
    _remote_expr(:_repl_client_connection, ex)
end

macro remote(conn, ex)
    _remote_expr(esc(conn), ex)
end

_remote_expr(conn, ex) = :(remote_eval_and_fetch($conn, $(QuoteNode(ex))))

#--------------------------------------------------
"""
    remote_eval(cmdstr)
    remote_eval(host, port, cmdstr)

Parse a string `cmdstr`, evaluate it in the remote REPL server's `Main` module,
then close the connection. Returns the result which the REPL would normally
pass to `show()` (likely a `Text` object).

For example, to cause the remote Julia instance to exit, you could use

```
using RemoteREPL
RemoteREPL.remote_eval("exit()")
```
"""
function remote_eval(host, port::Integer, cmdstr::AbstractString;
                     tunnel::Symbol = host!=Sockets.localhost ? :ssh : :none)
    conn = Connection(; host=host, port=port, tunnel=tunnel)
    local result
    try
        setup_connection!(conn)
        result = run_remote_repl_command(conn, IOBuffer(), cmdstr)
    finally
        close(conn)
    end
    return result
end

function remote_eval(cmdstr::AbstractString)
    remote_eval(Sockets.localhost, DEFAULT_PORT, cmdstr)
end
