"""
    tinf = SnoopCompile.flatten_demo()

A simple demonstration of [`@snoop_inference`](@ref). This demo defines a module

```julia
module FlattenDemo
    struct MyType{T} x::T end
    extract(y::MyType) = y.x
    function packintype(x)
        y = MyType{Int}(x)
        return dostuff(y)
    end
    function domath(x)
        y = x + x
        return y*x + 2*x + 5
    end
    dostuff(y) = domath(extract(y))
end
```

It then "warms up" (forces inference on) all of Julia's `Base` methods needed for `domath`,
to ensure that these MethodInstances do not need to be inferred when we collect the data.
It then returns the results of

```julia
@snoop_inference FlattenDemo.packintypes(1)
```

See [`flatten`](@ref) for an example usage.
"""
function flatten_demo()
    eval(:(
        module FlattenDemo
        struct MyType{T} x::T end
        extract(y::MyType) = y.x
        function packintype(x)
            y = MyType{Int}(x)
            return dostuff(y)
        end
        function domath(x)
            y = x + x
            return y*x + 2*x + 5
        end
        dostuff(y) = domath(extract(y))
        end
    ))
    z = (1 + 1)*1 + 2*1 + 5
    return @snoop_inference Base.invokelatest(FlattenDemo.packintype, 1)
end

"""
    tinf = SnoopCompile.itrigs_demo()

A simple demonstration of collecting inference triggers. This demo defines a module

```julia
module ItrigDemo
@noinline double(x) = 2x
@inline calldouble1(c) = double(c[1])
calldouble2(cc) = calldouble1(cc[1])
calleach(ccs) = (calldouble2(ccs[1]), calldouble2(ccs[2]))
end
```

It then "warms up" (forces inference on) `calldouble2(::Vector{Vector{Any}})`, `calldouble1(::Vector{Any})`, `double(::Int)`:

```julia
cc = [Any[1]]
ItrigDemo.calleach([cc,cc])
```

Then it collects and returns inference data using

```julia
cc1, cc2 = [Any[0x01]], [Any[1.0]]
@snoop_inference ItrigDemo.calleach([cc1, cc2])
```

This does not require any new inference for `calldouble2` or `calldouble1`, but it does force inference on `double` with two new types.
See [`inference_triggers`](@ref) to see what gets collected and returned.
"""
function itrigs_demo()
    eval(:(
        module ItrigDemo
        @noinline double(x) = 2x
        @inline calldouble1(c) = double(c[1])
        calldouble2(cc) = calldouble1(cc[1])
        calleach(ccs) = (calldouble2(ccs[1]), calldouble2(ccs[2]))
        end
    ))
    # Call once to infer `calldouble2(::Vector{Vector{Any}})`, `calldouble1(::Vector{Any})`, `double(::Int)`
    cc = [Any[1]]
    Base.invokelatest(ItrigDemo.calleach, [cc,cc])
    # Now use UInt8 & Float64 elements to force inference on double, without forcing new inference on its callers
    cc1, cc2 = [Any[0x01]], [Any[1.0]]
    return @snoop_inference Base.invokelatest(ItrigDemo.calleach, [cc1, cc2])
end

"""
    tinf = SnoopCompile.itrigs_higherorder_demo()

A simple demonstration of handling higher-order methods with inference triggers. This demo defines a module

```julia
module ItrigHigherOrderDemo
double(x) = 2x
@noinline function mymap!(f, dst, src)
    for i in eachindex(dst, src)
        dst[i] = f(src[i])
    end
    return dst
end
@noinline mymap(f::F, src) where F = mymap!(f, Vector{Any}(undef, length(src)), src)
callmymap(src) = mymap(double, src)
end
```

The key feature of this set of definitions is that the function `double` gets passed as an argument
through `mymap` and `mymap!` (the latter are [higher-order functions](https://en.wikipedia.org/wiki/Higher-order_function)).

It then "warms up" (forces inference on) `callmymap(::Vector{Any})`, `mymap(::typeof(double), ::Vector{Any})`,
`mymap!(::typeof(double), ::Vector{Any}, ::Vector{Any})` and `double(::Int)`:

```julia
ItrigHigherOrderDemo.callmymap(Any[1, 2])
```

Then it collects and returns inference data using

```julia
@snoop_inference ItrigHigherOrderDemo.callmymap(Any[1.0, 2.0])
```

which forces inference for `double(::Float64)`.

See [`skiphigherorder`](@ref) for an example using this demo.
"""
function itrigs_higherorder_demo()
    eval(:(
        module ItrigHigherOrderDemo
        double(x) = 2x
        @noinline function mymap!(f, dst, src)
            for i in eachindex(dst, src)
                dst[i] = f(src[i])
            end
            return dst
        end
        @noinline mymap(f::F, src) where F = mymap!(f, Vector{Any}(undef, length(src)), src)
        callmymap(src) = mymap(double, src)
        end
    ))
    # Call once to infer `callmymap(::Vector{Any})`, `mymap(::typeof(double), ::Vector{Any})`,
    #    `mymap!(::typeof(double), ::Vector{Any}, ::Vector{Any})` and `double(::Int)`
    Base.invokelatest(ItrigHigherOrderDemo.callmymap, Any[1, 2])
    src = Any[1.0, 2.0]   # double not yet inferred for Float64
    return @snoop_inference Base.invokelatest(ItrigHigherOrderDemo.callmymap, src)
end

