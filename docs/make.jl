using Documenter, RemoteREPL

makedocs(;
    modules=[RemoteREPL],
    format=Documenter.HTML(),
    pages=[
        "Overview"          => "index.md",
        "Tutorial"          => "tutorial.md",
        "How To"            => "howto.md",
        "Reference"         => "reference.md",
        "Design"            => "design.md",
        "Troubleshooting"   => "troubleshooting.md",
    ],
    repo="https://github.com/c42f/RemoteREPL.jl/blob/{commit}{path}#L{line}",
    sitename="RemoteREPL.jl",
    authors = "Chris Foster and contributors: https://github.com/c42f/RemoteREPL.jl/graphs/contributors"
)

deploydocs(;
    repo="github.com/c42f/RemoteREPL.jl",
    devbranch="main",
    push_preview=true
)
