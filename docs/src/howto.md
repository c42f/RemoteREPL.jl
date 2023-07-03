# How-To

## Serve a REPL from a remote server

1. Run an ssh server on `your.example.host` and perform the usual ssh setup.
   (For example, add your public key to `~/.ssh/authorized_keys` on the server.)
2. Your Julia server should call `serve_repl()`. Use `@async serve_repl()` if
   you'd like to run other server tasks concurrently.

## Connect to a REPL on a remote server

1. Set up passwordless ssh to your server. Usually this means you have
   `ssh-agent` running with your private key loaded. If you've got some
   particular ssh options needed for the server, you'll find it convenient to
   set these up in the OpenSSH config file (`~/.ssh/config` on unix). For
   example,
   ```ssh-config
   Host your.example.host
      User ubuntu
      IdentityFile ~/.ssh/some_identity
   ```
2. Start up Julia and run the code
   ```julia
   using RemoteREPL; connect_repl("your.example.host");
   ```
   Alternatively use the shell wrapper script `RemoteREPL/bin/julia-r`:
   ```bash
   julia-r your.example.host
   ```


## Plot variables from the server

The [`@remote`](@ref) macro can be used to get variables from the server and
plot them on the client with a single line of code. For example:

```julia
julia@your.host> x = 1:42; y = x.^2;

julia> plot(@remote((x,y))...)
```

## Use `stdout` with `println`/`dump`, etc

Lots of functions such as `print` write to the global `stdout` variable, but
`RemoteREPL` doesn't capture this.

There's two ways to get a similar effect in `RemoteREPL`, both of which rely on
passing an `IO` object explicitly to `println`/`dump`/etc.

One way is to use `@remote(stdout)` which creates a proxy of the client's
`stdout` stream on the server which you can write to:

```julia
julia@localhost> dump(@remote(stdout), :(a + b))
Expr
  head: Symbol call
  args: Array{Any}((3,))
    1: Symbol +
    2: Symbol a
    3: Symbol b
```

Another way is to use `sprint` to create the `IO` object and wrap the returned
value in a `Text` object for display:

```julia
julia@localhost> Text(sprint(dump, :(a+b)))
Expr
  head: Symbol call
  args: Array{Any}((3,))
    1: Symbol +
    2: Symbol a
    3: Symbol b
```

## Include a remote file

To include a Julia source file from the client into the current module on the
remote side, use the `%include` REPL magic:

```julia
julia@localhost> %include some/file.jl
```

`%include` has tab completion for local paths on the client.

## Evaluate commands in another module

If your server process has state in another module, you can tell RemoteREPL to
evaluate all commands in that module. For example:

```julia
julia@localhost> module SomeMod
                    a_variable = 1
                 end
Main.SomeMod

julia@localhost> a_variable
ERROR: UndefVarError: a_variable not defined
[...]

julia@localhost> %module SomeMod
Evaluating commands in module Main.SomeMod

julia@localhost> a_variable
1
```


## Use common session among different clients
A session, as implemented in `ServerSideSession`, describes the display properties and the module under which commands are evaluated.
Multiple clients can share same such properties by using the same `session_id`. For example:

```julia
julia> session_id = UUID("f03aec15-3e14-4d58-bcfa-82f8d33c9f9a")

julia> connect_repl(; session_id=session_id)
```

## Pass a command non-interactively
To programmatically pass a command to the remote julia kernel use [`remotecmd`](@ref). For example:

```julia
julia> con2server = connect_remote(Sockets.localhost, 9093) # connect to port 9093 in localhost

julia> remotecmd(con2server, "myvar = 1") # define a new var
```

## Use alternatives to SSH

### AWS Session Manager

You can use [AWS Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) instead of SSH to connect to remote hosts. To do this, first setup Session Manager for the EC2 instances you like. See the [docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-getting-started.html). Thereafter, install [AWS CLI version 2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) and then install the [Session Manager plugin for AWS CLI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) on your local system.

Setup your AWS CLI by running `aws configure` on the command line. You can then connect to the RemoteREPL server on your EC2 instance with `connect_repl("your-instance-id"; tunnel=:aws, region="your-instance-region")`. The `region` argument is only required if the EC2 instance is not in the default region that your CLI was setup with.

### Kubernetes `kubectl`

If [kubectl](https://kubernetes.io/docs/reference/kubectl/overview/) is configured on your local system, you can use that to connect to RemoteREPL servers on your Kubernetes cluster. Run the following snippet: `connect_repl("your-pod-name"; tunnel=:k8s, namespace="your-namespace")`. The `namespace` argument is only required if the Pod is not in the default Kubernetes namespace.

## Use in Jupyter or Pluto

In environments without any REPL integrations like Jupyter or Pluto notebooks you can use

```julia
connect_remote();
```
which will allow you to use `@remote` without the REPL mode.

### More on Pluto
Pluto presents a peculiarity as the default module is constantly changing.
In order to closely track the newest notebook state, you will need to tap into the client's session and update the module.
You could write the following code in the pluto notebook that updates the module every second (if you have a better event-driven update solution, please raise an issue!).

```julia
using PlutoLinks, PlutoHooks

using RemoteREPL, Sockets, UUIDs

server = Sockets.listen(Sockets.localhost, 27765)

@async serve_repl(server)

session_id = UUID("f03aec15-3e14-4d58-bcfa-82f8d33c9f9a")

con2server = connect_remote(Sockets.localhost, 27765; session_id=session_id)

takemodulesymbol() = Symbol("workspace#" ,PlutoRunner.moduleworkspace_count[])

let # update module in RemoteREPL every 1 sec
	count, set_count = @use_state(1)
	@use_task([]) do
		new_count = count
		while true
			sleep(1.0)
			new_count += 1
			set_count(new_count) # (this will trigger a re-run)
		end
	end
	mod = eval(takemodulesymbol())
	#@eval(@remoterepl $"%module $mod")
	remote_module!(mod)
end
```

Then open a repl and do:

```julia
julia> using RemoteREPL, Sockets, UUIDs

julia> connect_repl(Sockets.localhost, 27765; session_id=UUID("f03aec15-3e14-4d58-bcfa-82f8d33c9f9a"))
```

Since the session's module is being regularly updated by the Pluto notebook, your REPL will be in sync with the notebook's state.

