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
   example, the config file could contain the following:
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
## Troubleshooting connection issues 
Sometimes errors will be encountered. This section aims to show some errors experienced by users, and what the underlying problem was. We will use some terms in this section, introduced in the table below.
|Term|Explanation|
|---|---|
|"local REPL"|a REPL running on the same computer as the host. This could mean connecting two julia instances running on the same computer.|
|"remote REPL"|a REPL running on a different computer than the host.|
|"address"|a placeholder for the address you connect to, typically an IP-address. Examples of what an actual address could look like include "pi@192.168.4.2" and "youruser@example.com".|

### Error: `IOError: connect: connection refused (ECONNREFUSED)`
This error has been encountered when
1) Running `connect_repl()` or `connect_remote()`, while attempting to connect to a local REPL. The problem was that no local REPL had previously run `serve_repl()`. To fix this, run `serve_repl()` in the local REPL.
2) Running `connect_remote()`, while attempting to connect to a remote REPL. The problem was that no address was provided. To fix this, pass an address as a string to `connect_remote`, as in `connect_remote("address")`

### Error: `RemoteREPL stream was closed while reading header`
This error has been encountered when running `connect_remote("address")` or `connect_repl("address")`, while attempting to connect to a remote REPL. The problem was that the remote REPL had not previously run `serve_repl()`. To fix this, run `serve_repl()` in the remote REPL.

### Error: `Bad owner or permissions on /home/username/.ssh/config`
This error is raised by [this](https://github.com/openssh/openssh-portable/blob/947a3e829a5b8832a4768fd764283709a4ca7955/readconf.c#L1711) line of code, from OpenSSH. 
The requirements translates to that "the config file must be owned by root or by the user running the ssh and can not be writable by any group or other users." 
(Quoted from [this](https://superuser.com/questions/1212402/bad-owner-or-permissions-on-ssh-config-file) thread). The fix is therefore to remove write permissions for 
any group or other users. On a linux system, this is accomplished by running the following code.
```
chmod go-w /home/username/.ssh/*
```
If you are using a different operating system, please google how to remove write permissions on files, and try to do the same thing.
