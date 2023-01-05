function topmodule(mods)
    function ischild(c, mod)
        ok = false
        pc = parentmodule(c)
        while pc !== c
            pc === Main && return false  # mostly important for passing the tests
            if isdefined(mod, nameof(pc))
                ok = true
                break
            end
            c = pc
        end
        return ok
    end

    mods = collect(mods)
    mod = first(mods)
    for m in Iterators.drop(mods, 1)
        # Easy cases
        if isdefined(mod, nameof(m))
        elseif isdefined(m, nameof(mod))
            mod = m
        else
            # Check parents of each
            if ischild(m, mod)
            elseif ischild(mod, m)
                mod = m
            else
                return nothing
            end
        end
    end
    return mod
end

function addmodules!(mods, parameters)
    for p in parameters
        if isa(p, DataType)
            push!(mods, Base.moduleroot(p.name.module))
            addmodules!(mods, p.parameters)
        end
    end
    return mods
end

function methods_with_generators(m::Module)
    meths = Method[]
    for name in names(m; all=true)
        isdefined(m, name) || continue
        f = getfield(m, name)
        if isa(f, Function)
            for method in methods(f)
                if isdefined(method, :generator)
                    push!(meths, method)
                end
            end
        end
    end
    return meths
end

# Code to look up keyword-function "body methods"
const lookup_kwbody_str = """
const __bodyfunction__ = Dict{Method,Any}()

# Find keyword "body functions" (the function that contains the body
# as written by the developer, called after all missing keyword-arguments
# have been assigned values), in a manner that doesn't depend on
# gensymmed names.
# `mnokw` is the method that gets called when you invoke it without
# supplying any keywords.
function __lookup_kwbody__(mnokw::Method)
    function getsym(ast, arg)
        isa(arg, Symbol) && return arg
        isa(arg, GlobalRef) && return arg.name
        if isa(arg, Core.SSAValue)
            arg = ast.code[arg.id]
            return getsym(ast, arg)
        end
    end

    f = get(__bodyfunction__, mnokw, nothing)
    if f === nothing
        fmod = mnokw.module
        # The lowered code for `mnokw` should look like
        #   %1 = mkw(kwvalues..., #self#, args...)
        #        return %1
        # where `mkw` is the name of the "active" keyword body-function.
        ast = Base.uncompressed_ast(mnokw)
        if isa(ast, Core.CodeInfo) && length(ast.code) >= 2
            callexpr = ast.code[end-1]
            if isa(callexpr, Expr) && callexpr.head == :call
                fsym = callexpr.args[1]
                if isa(fsym, Symbol)
                    f = getfield(fmod, fsym)
                elseif isa(fsym, GlobalRef)
                    if fsym.mod === Core && fsym.name === :_apply
                        f = getfield(mnokw.module, getsym(ast, callexpr.args[2]))
                    elseif fsym.mod === Core && fsym.name === :_apply_iterate
                        f = getfield(mnokw.module, getsym(ast, callexpr.args[3]))
                    else
                        f = getfield(fsym.mod, fsym.name)
                    end
                else
                    f = missing
                end
            else
                f = missing
            end
        else
            f = missing
        end
        __bodyfunction__[mnokw] = f
    end
    return f
end
"""

const lookup_kwbody_ex = Expr(:toplevel)
start = 1
while true
    global start
    ex, start = Meta.parse(lookup_kwbody_str, start)
    if ex !== nothing
        push!(lookup_kwbody_ex.args, ex)
    else
        break
    end
end

"""
    can_eval(mod::Module, str::AbstractString, check_eval::Bool=true)

Checks if the precompilation statement can be evaled.

In some cases, you may want to bypass this function by passing `check_eval=true` to increase the snooping performance.
"""
function can_eval(mod::Module, str::AbstractString, check_eval::Bool=true)
    if check_eval
        try
            ex = Meta.parse(str)
            if mod === Core
                #https://github.com/timholy/SnoopCompile.jl/issues/76
                Core.eval(Main, ex)
            else
                Core.eval(mod, ex)
            end
        catch e
            return false, e
        end
    end
    return true, nothing
end

tupletypestring(params) = "Tuple{" * join(params, ',') * '}'
tupletypestring(fstr::AbstractString, params::AbstractVector{<:AbstractString}) =
    tupletypestring([fstr; params])

tuplestring(params) = isempty(params) ? "()" : '(' * join(params, ',') * ",)"

wrap_precompile(ttstr::AbstractString) = "Base.precompile(" * ttstr * ')' # use `Base.` to avoid conflict with Core and Pkg

append_time(str, ::Nothing) = str
append_time(str, t::AbstractFloat) = str * "   # time: " * string(Float32(t))

"""
     add_if_evals!(pclist, mod::Module, fstr, params, tt; prefix = "", check_eval::Bool=true)

Adds the precompilation statements only if they can be evaled. It uses [`can_eval`](@ref) internally.

In some cases, you may want to bypass this function by passing `check_eval=true` to increase the snooping performance.
"""
function add_if_evals!(pclist, mod::Module, fstr, params, tt; prefix = "", check_eval::Bool=true, time=nothing)
    ttstr = tupletypestring(fstr, params)
    can, exc = can_eval(mod, ttstr, check_eval)
    if can
        push!(pclist, append_time(prefix*wrap_precompile(ttstr), time))
        return true
    else
        @debug "Module $mod: skipping $tt due to eval failure" exception=exc _module=mod _file="precompile_$mod.jl"
    end
    return false
end

function reprcontext(mod::Module, @nospecialize(T))
    # First check whether supplying module context allows evaluation
    rplain = repr(T; context=:module=>mod)
    try
        ex = Meta.parse(rplain)
        Core.eval(mod, ex)
        return rplain
    catch
        # Add full module context
        return repr(T; context=:module=>nothing)
    end
end

let known_type_cache = IdDict{Tuple{Module,Tuple{Vararg{Symbol}},Symbol},Bool}()
    global known_type
    function known_type(mod::Module, @nospecialize(T::Union{Type,TypeVar}))
        function startswith(@nospecialize(a::Tuple{Vararg{Symbol}}), @nospecialize(b::Tuple{Vararg{Symbol}}))
            length(b) >= length(a) || return false
            for i = 1:length(a)
                a[i] == b[i] || return false
            end
            return true
        end
        function firstname(@nospecialize(tpath::Tuple{Vararg{Symbol}}))
            i = 1
            while i <= length(tpath)
                sym = tpath[i]
                sym === :Main || return sym
                i += 1
            end
            return :ISNOTAMODULENAME
        end
        strippedname(tn::Core.TypeName) = Symbol(string(tn.name)[2:end])

        if isa(T, TypeVar)
            return known_type(mod, T.ub) && known_type(mod, T.lb)
        end
        T === Union{} && return true
        T = Base.unwrap_unionall(T)
        if isa(T, Union)
            return known_type(mod, T.a) & known_type(mod, T.b)
        end
        T = T::DataType
        tn = T.name
        tpath = fullname(tn.module)
        key = (mod, tpath, tn.name)
        kt = get(known_type_cache, key, nothing)
        if kt === nothing
            kt = startswith(fullname(mod), tpath) ||
                 ccall(:jl_get_module_of_binding, Ptr{Cvoid}, (Any, Any), mod, firstname(tpath)) != C_NULL ||
                 (isdefined(mod, tn.name) && (T2 = getfield(mod, tn.name); isa(T2, Type) && Base.unwrap_unionall(T2) === T)) ||
                 (T <: Function && isdefined(mod, strippedname(tn)) && (f = getfield(mod, strippedname(tn)); typeof(f) === T))
            known_type_cache[key] = kt
        end
        kt === false && return false
        for p in T.parameters
            isa(p, Type) || continue
            known_type(mod, p) || return false
        end
        return true
    end
end

function handle_kwbody(topmod::Module, m::Method, paramrepr, tt, fstr="fbody"; check_eval = true, has_bodyfunction::Bool=false)
    nameparent = Symbol(match(r"^#([^#]*)#", String(m.name)).captures[1])
    if !isdefined(m.module, nameparent)
        @debug "Module $topmod: skipping $m due to inability to look up kwbody parent" # see example related to issue #237
        return nothing
    end
    fparent = getfield(m.module, nameparent)
    pttstr = tuplestring(paramrepr[m.nkw+2:end])
    whichstr = "which($nameparent, $pttstr)"
    can1, exc1 = can_eval(topmod, whichstr, check_eval)
    if can1
        ttstr = tuplestring(paramrepr)
        pcstr = has_bodyfunction ? """
            let fbody = try Base.bodyfunction($whichstr) catch missing end
                if !ismissing(fbody)
                    precompile($fstr, $ttstr)
                end
            end""" : """
            let fbody = try __lookup_kwbody__($whichstr) catch missing end
                if !ismissing(fbody)
                    precompile($fstr, $ttstr)
                end
            end"""  # extra indentation because `write` will indent 1st line
        can2, exc2 = can_eval(topmod, pcstr, check_eval)
        if can2
            return pcstr
        else
            @debug "Module $topmod: skipping $tt due to kwbody lookup failure" exception=exc2 _module=topmod _file="precompile_$topmod.jl"
        end
    else
        @debug "Module $topmod: skipping $tt due to kwbody caller lookup failure" exception=exc1 _module=topmod _file="precompile_$topmod.jl"
    end
    return nothing
end

function parcel(tinf::AbstractVector{Tuple{Float64, Core.MethodInstance}};
    subst = Vector{Pair{String, String}}(),
    exclusions = String[],
    remove_exclusions::Bool = true,
    check_eval::Bool = true,
    has_bodyfunction::Bool = false,     # can set to true if your package only supports Julia 1.6+
    blacklist=nothing,                  # deprecated keyword
    remove_blacklist=nothing)           # deprecated keyword

    if blacklist !== nothing
        Base.depwarn("`blacklist` is deprecated, please use `exclusions` to pass a list of excluded names", :parcel)
        append!(exclusions, blacklist)
    end
    if remove_blacklist !== nothing
        Base.depwarn("`remove_blacklist` is deprecated, please use `remove_exclusions` to pass a list of excluded names", :parcel)
        remove_exclusions = remove_blacklist
    end

    pc = Dict{Symbol, Set{String}}()         # output
    modgens = Dict{Module, Vector{Method}}() # methods with generators in a module
    mods = OrderedSet{Module}()                     # module of each parameter for a given method
    sym_module = Dict{Symbol, Module}() # 1-1 association between modules and module name
    for (_, mi) in reverse(tinf)
        isdefined(mi, :specTypes) || continue
        tt = mi.specTypes
        m = mi.def
        isa(m, Method) || continue
        # Determine which module to assign this method to. All the types in the arguments
        # need to be defined; we collect all the corresponding modules and assign it to the
        # "topmost".
        empty!(mods)
        mroot = Base.moduleroot(m.module)
        push!(mods, mroot)
        addmodules!(mods, tt.parameters)
        topmod = topmodule(mods)
        if topmod === nothing
            @debug "Skipping $tt due to lack of a suitable top module"
            continue
        elseif topmod !== mroot
            @debug "Skipping $tt due to lack of method ownership"
            continue
        end
        # If we haven't yet started the list for this module, initialize
        topmodname = nameof(topmod)
        sym_module[topmodname] = topmod
        if !haskey(pc, topmodname)
            pc[topmodname] = Set{String}()
            # For testing our precompile directives, we might need to have lookup available
            if VERSION >= v"1.4.0-DEV.215" && topmod !== Core && !isdefined(topmod, :__bodyfunction__)
                Core.eval(topmod, lookup_kwbody_ex)
            end
        end
        add_repr!(pc[topmodname], modgens, mi, topmod; check_eval=check_eval, has_bodyfunction=has_bodyfunction)
    end

    # loop over the output
    for mod in keys(pc)
        # exclusions remover
        if remove_exclusions
            pc[mod] = exclusions_remover!(pc[mod], exclusions)
        end
    end
    return Dict(mod=>collect(lines) for (mod, lines) in pc) # convert Set to Array before return
end

function add_repr!(list, modgens::Dict{Module, Vector{Method}}, mi::MethodInstance, topmod::Module=mi.def.module; check_eval::Bool, time=nothing, kwargs...)
    # Create the string representation of the signature
    # Use special care with keyword functions, anonymous functions
    tt = Base.unwrap_unionall(mi.specTypes)
    m = mi.def
    p = tt.parameters[1]   # the portion of the signature related to the function itself
    paramrepr = map(T->reprcontext(topmod, T), Iterators.drop(tt.parameters, 1))  # all the rest of the args

    if any(str->occursin('#', str), paramrepr)
        @debug "Skipping $tt due to argument types having anonymous bindings"
        return false
    end
    mname, mmod = String(Base.unwrap_unionall(p).name.name), m.module   # m.name strips the kw identifier
    mkw = match(kwrex, mname)
    mkwbody = match(kwbodyrex, mname)
    isgen = match(genrex, mname) !== nothing
    isanon = match(anonrex, mname) !== nothing || match(innerrex, mname) !== nothing
    isgen && (mkwbody = nothing)
    if VERSION < v"1.4.0-DEV.215"  # before this version, we can't robustly look up kwbody callers (missing `nkw`)
        isanon |= mkwbody !== nothing  # treat kwbody methods the same way we treat anonymous functions
        mkwbody = nothing
    end
    if mkw !== nothing
        # Keyword function
        fname = mkw.captures[1] === nothing ? mkw.captures[2] : mkw.captures[1]
        fkw = "Core.kwftype(typeof($fname))"
        return add_if_evals!(list, topmod, fkw, paramrepr, tt; check_eval=check_eval, time=time)
    elseif mkwbody !== nothing
        ret = handle_kwbody(topmod, m, paramrepr, tt; check_eval = check_eval, kwargs...)
        if ret !== nothing
            push!(list, append_time(ret, time))
            return true
        end
    elseif isgen
        # Generator for a @generated function
        if !haskey(modgens, m.module)
            callers = modgens[m.module] = methods_with_generators(m.module)
        else
            callers = modgens[m.module]
        end
        for caller in callers
            if nameof(caller.generator.gen) == m.name
                # determine whether the generator is being called from a kwbody method
                sig = Base.unwrap_unionall(caller.sig)
                cname, cmod = String(sig.parameters[1].name.name), caller.module
                cparamrepr = map(repr, Iterators.drop(sig.parameters, 1))
                csigstr = tuplestring(cparamrepr)
                mkwc = match(kwbodyrex, cname)
                if mkwc === nothing
                    getgen = "typeof(which($(caller.name),$csigstr).generator.gen)"
                    return add_if_evals!(list, topmod, getgen, paramrepr, tt; check_eval=check_eval, time=time)
                else
                    if VERSION >= v"1.4.0-DEV.215"
                        getgen = "which(Core.kwfunc($(mkwc.captures[1])),$csigstr).generator.gen"
                        ret = handle_kwbody(topmod, caller, cparamrepr, tt; check_eval = check_eval, kwargs...) #, getgen)
                        if ret !== nothing
                            push!(list, append_time(ret, time))
                            return true
                        end
                    else
                        # Bail and treat as if anonymous
                        prefix = "isdefined($mmod, Symbol(\"$mname\")) && "
                        fstr = "getfield($mmod, Symbol(\"$mname\"))"  # this is universal, var is Julia 1.3+
                        return add_if_evals!(list, topmod, fstr, paramrepr, tt; prefix=prefix, check_eval=check_eval, time=time)
                    end
                end
                break
            end
        end
    elseif isanon
        # Anonymous function, wrap in an `isdefined`
        prefix = "isdefined($mmod, Symbol(\"$mname\")) && "
        fstr = "getfield($mmod, Symbol(\"$mname\"))"  # this is universal, var is Julia 1.3+
        return add_if_evals!(list, topmod, fstr, paramrepr, tt; prefix=prefix, check_eval = check_eval, time=time)
    end
    return add_if_evals!(list, topmod, reprcontext(topmod, p), paramrepr, tt, check_eval = check_eval, time=time)
end

"""
    exclusions_remover!(pcI, exclusions)

Search and removes terms appearing in `exclusions` from `pcI`.

By default it considers some strings as exclusions such as `r"\\bMain\\b"`.

# Examples
```julia
exclusions = Set(["hi","bye"])
pcI = Set(["good","bad","hi","bye","no"])

SnoopCompile.exclusions_remover!(pcI, exclusions)
```
"""
function exclusions_remover!(pcI::AbstractSet, exclusions)
    all_exclusions = union(exclusions, default_exclusions)

    # We can't just use `setdiff!` because this is a substring search
    todelete = Set{eltype(pcI)}()
    for line in pcI
        if any(occursin.(all_exclusions, line))
            push!(todelete, line)
        end
    end
    return setdiff!(pcI, todelete)
end

# These are found by running `exhaustive_remover!` on some packages
const default_exclusions = Set([
    r"\bMain\b",
])
