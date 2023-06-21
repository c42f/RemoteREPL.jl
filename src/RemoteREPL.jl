module RemoteREPL

using REPL, ReplMaker
using Sockets, Serialization
using UUIDs, Logging
using OpenSSH_jll

export connect_repl, serve_repl, @remote, connect_remote, run_remote_repl_command, remote_module!

const DEFAULT_PORT = 27754
const PROTOCOL_MAGIC = "RemoteREPL"
const PROTOCOL_VERSION = UInt32(1)

const STDOUT_PLACEHOLDER = Symbol("#RemoteREPL_STDOUT_PLACEHOLDER")

include("tunnels.jl")
include("server.jl")
include("client.jl")

end
