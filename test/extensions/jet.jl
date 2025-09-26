using SnoopCompileCore
using SnoopCompile
using Test
using JET, Cthulhu

# NOTE: the JET test is handled specially in `.github/workflows/ci.yml`

@testset "JET integration" begin
    function mysum(c)   # vendor a simple version of `sum`
        isempty(c) && return zero(eltype(c))
        s = first(c)
        for x in Iterators.drop(c, 1)
            s += x
        end
        return s
    end
    call_mysum(cc) = mysum(cc[1])

    cc = Any[Any[1,2,3]]
    tinf = @snoop_inference call_mysum(cc)
    rpt = @report_call call_mysum(cc)
    @test isempty(JET.get_reports(rpt))
    itrigs = inference_triggers(tinf)
    irpts = report_callees(itrigs)
    @test only(irpts).first == last(itrigs)
    @test !isempty(JET.get_reports(only(irpts).second))
    @test  isempty(JET.get_reports(report_caller(itrigs[end])))
end
