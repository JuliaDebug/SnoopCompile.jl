module CthulhuExtTest

using SnoopCompileCore, SnoopCompile
using Cthulhu
using Cthulhu.Testing
using Pkg
using Test

@static if Base.pkgversion(Cthulhu) < v"3.0.0-"
    const VirtualTerminal = FakeTerminal
end

# NOTE: the Cthulhu test is handled specially in `.github/workflows/ci.yml`

macro with_try_stderr(out, expr)
    quote
        try
            $(esc(expr))
        catch err
            bt = catch_backtrace()
            Base.display_error(stderr, err, bt)
        end
    end
end

# Test functions
myplus(x, y) = x + y
function f(x)
    x < 0.25 ? 1 :
    x < 0.5  ? 1.0 :
    x < 0.75 ? 0x01 : Float16(1)
end
g(c) = myplus(f(c[1]), f(c[2]))

cread1(terminal) = readuntil(terminal.output, ')'; keep=true)
cread(terminal, until) = cread(terminal, "", until)
cread(terminal, str, until) = occursin(until, str) ? str : cread(terminal, str * cread1(terminal), until)
strip_ansi_escape_sequences(str) = replace(str, r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])" => "")
function read_from(terminal, until)
    displayed = cread(terminal, until)
    text = strip_ansi_escape_sequences(displayed)
    return (displayed, text)
end

@testset "Cthulhu extension" begin
    @testset "ascend for invalidations" begin
        cproj = Base.active_project()
        cd(joinpath(dirname(@__DIR__), "testmodules", "Invalidation")) do
            Pkg.activate(pwd())
            Pkg.instantiate()
            Pkg.precompile()
            invalidations = @snoop_invalidations begin
                @eval begin
                    using PkgC
                    PkgC.nbits(::UInt8) = 8
                    using PkgD
                end
            end
            trees = invalidation_trees(invalidations)
            tree = last(trees)
            sig, root = only(tree.mt_backedges)

            term = VirtualTerminal()
            t = @async begin
                @with_try_stderr term.output redirect_stderr(term.error) do
                    ascend(term, root)
                end
            end
            displayed, text = read_from(term, "map_nbits")
            @test occursin("call_nbits", text)
            @test occursin("map_nbits(::Vector{Integer})", text)
            # the job of the extension is done once we've written the menu, so we can quit here
            write(term.input, 'q')
            readavailable(term.output)
            wait(t)
            finalize(term)
        end

        Pkg.activate(cproj)
    end

    @testset "ascend for inference triggers" begin
        tinf = @snoop_inference g([0.7, 0.8])
        itrigs = inference_triggers(tinf; exclude_toplevel=false)
        itrig = last(itrigs)

        term = VirtualTerminal()
        t = @async begin
            @with_try_stderr term.output ascend(term, itrig; interruptexc=false)
        end
        displayed, text = read_from(term, "g(::Vector{Float64})")
        @test occursin("myplus(::UInt8, ::Float16)", text)
        @test occursin("g(::Vector{Float64})", text)
        # the job of the extension is done once we've written the menu, so we can quit here
        write(term.input, 'q')
        readavailable(term.output)
        wait(t)
        finalize(term)
    end
end

end # module
