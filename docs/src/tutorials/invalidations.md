# Tutorial on `@snoop_invalidations`

## What are invalidations?

In this context, *invalidation* means discarding previously-compiled code. Invalidations occur because of interactions between independent pieces of code. Invalidations are essential to make Julia fast, interactive, and correct: you *need* invalidations if you want to be able to define some methods, run (compile) some code, and then in the same session define new methods that might lead to different answers if you were to recompile the code in the presence of the new methods.

Invalidations can happen just from loading packages. Packages are precompiled in isolation, but you can load many packages into a single interactive session. It's impossible for the individual packages to anticipate the full "world of methods" in your interactive session, so sometimes Julia has to discard code that was compiled in a smaller world because it's at risk for being incorrect in the larger world.

The downside of invalidations is that they make latency worse, as code must be recompiled when you first run it. The benefits of precompilation are partially lost, and the work done during precompilation is partially wasted.

While some invalidations are unavoidable, in practice a good developer can often design packages to minimize the number and/or impact of invalidations. Invalidation-resistant code is often faster, with smaller binary size, than code that is vulnerable to invalidation.

A good first step is to measure what's being invalidated, and why.

## Learning to observe, diagnose, and fix invalidations

We'll illustrate invalidations by creating two packages, where loading the second package invalidates some code that was compiled in the first one. We'll then go over approaches for "fixing" invalidations (i.e., preventing them from occuring).

!!! tip
    Since SnoopCompile's tools are interactive, you are strongly encouraged to try these examples yourself as you read along.

### Add SnoopCompileCore, SnoopCompile, and helper packages to your environment

Here, we'll add these packages to your [default environment](https://pkgdocs.julialang.org/v1/environments/). (With the exception of `AbstractTrees`, these "developer tool" packages should not be added to the Project file of any real packages unless you're extending the tool itself.) From your default environment (i.e., in package mode you should see something like `(@v1.10) pkg>`), do

```
using Pkg
Pkg.add(["SnoopCompileCore", "SnoopCompile", "AbstractTrees", "Cthulhu"]);
```

### Create the demonstration packages

We're going to implement a toy version of the card game [blackjack](https://www.wikihow.com/Play-Blackjack), where players take cards with the aim of collecting 21 points. The higher you go the better, *unless* you go over 21 points, in which case you "go bust" (i.e., you lose). Because our real goal is to illustrate invalidations, we'll create a "blackjack ecosystem" that involves an interaction between two packages.

While [PkgTemplates](https://github.com/JuliaCI/PkgTemplates.jl) is recommended for creating packages, here we'll just use the basic capabilities in `Pkg`.
To create the (empty) packages, the code below executes the following steps:
- navigate to a temporary directory and create both packages
- make the first package (`Blackjack`) depend on [PrecompileTools](https://github.com/JuliaLang/PrecompileTools.jl) (we're interested in reducing latency!)
- make the second package (`BlackjackFacecards`) depend on the first one (`Blackjack`)

```@repl tutorial-invalidations
oldproj = Base.active_project()   # hide
cd(mktempdir())
using Pkg
Pkg.generate("Blackjack");
Pkg.activate("Blackjack")
Pkg.add("PrecompileTools");
Pkg.generate("BlackjackFacecards");
Pkg.activate("BlackjackFacecards")
Pkg.develop(PackageSpec(path=joinpath(pwd(), "Blackjack")));
```

Now it's time to create the code for `Blackjack`. Normally, you'd do this with an editor, but to make it reproducible here we'll use code to create these packages. The package code we'll create below defines the following:
- a `score` function to assign a numeric value to a card
- `tallyscore` which adds the total score for a hand of cards
- `playgame` which uses a simple strategy to decide whether to take another card from the deck and add it to the hand

To reduce latency on first use, we then precompile `playgame`. In a real application, we'd also want a function to manage the `deck` of cards, but for brevity we'll omit this and do it manually.

```@repl tutorial-invalidations
write(joinpath("Blackjack", "src", "Blackjack.jl"), """
    module Blackjack

    using PrecompileTools

    export playgame

    const deck = []   # the deck of cards that can be dealt

    # Compute the score of one card
    score(card::Int) = card

    # Add up the score in a hand of cards
    function tallyscores(cards)
        s = 0
        for card in cards
            s += score(card)
        end
        return s
    end

    # Play the game! We use a simple strategy to decide whether to draw another card.
    function playgame()
        myhand = []
        while tallyscores(myhand) <= 14 && !isempty(deck)
            push!(myhand, pop!(deck))   # "Hit me!"
        end
        myscore = tallyscores(myhand)
        return myscore <= 21 ? myscore : "Busted"
    end

    # Precompile `playgame`:
    @setup_workload begin
        push!(deck, 8, 10)    # initialize the deck
        @compile_workload begin
            playgame()
        end
    end

    end
    """)
```

Suppose you use `Blackjack` and like it, but you notice it doesn't support face cards. Perhaps you're nervous about contributing to the `Blackjack` package (you shouldn't be!), and so you decide to start your own package that extends its functionality. You create `BlackjackFacecards` to add scoring of the jack, queen, king, and ace (for simplicity we'll make the ace always worth 11):

```@repl tutorial-invalidations
write(joinpath("BlackjackFacecards", "src", "BlackjackFacecards.jl"), """
    module BlackjackFacecards

    using Blackjack

    # Add a new `score` method:
    Blackjack.score(card::Char) = card ∈ ('J', 'Q', 'K') ? 10 :
                                  card == 'A' ? 11 : error(card, " not known")

    end
    """)
```

!!! warning
    Because `BlackjackFacecards` "owns" neither `Char` nor `score`, this is [piracy](https://docs.julialang.org/en/v1/manual/style-guide/#Avoid-type-piracy-1) and should generally be avoided. Piracy is one way to cause invalidations, but it's not the only one. `BlackjackFacecards` could avoid committing piracy by defining a `struct Facecard ... end` and defining `score(card::Facecard)` instead of `score(card::Char)`. However, this would *not* fix the invalidations--all the factors described below are unchanged.

Now we're ready!

### Recording invalidations

Here are the steps executed by the code below
- load `SnoopCompileCore`
- load `Blackjack` and `BlackjackFacecards` while *recording invalidations* with the `@snoop_invalidations` macro.
- load `SnoopCompile` and `AbstractTrees` for analysis

```@repl tutorial-invalidations
using SnoopCompileCore
invs = @snoop_invalidations using Blackjack, BlackjackFacecards;
using SnoopCompile, AbstractTrees
```

!!! tip
    If you get errors like `Package SnoopCompileCore not found in current path`, a likely explanation is that
    you didn't add it to your default environment. In the example above, we're in the `BlackjackFacecards` environment
    so we can develop the package, but you also need access to `SnoopCompile` and `SnoopCompileCore`. Having these in your [default environment](https://docs.julialang.org/en/v1/manual/code-loading/#Environment-stacks) lets them be found even if they aren't part of the current environment.

### Analyzing invalidations

Now we're ready to see what, if anything, got invalidated:

```@repl tutorial-invalidations
trees = invalidation_trees(invs)
```

This has only one "tree" of invalidations. `trees` is a `Vector` so we can index it:

```@repl tutorial-invalidations
tree = trees[1]
```

Each tree stems from a single *cause* described in the top line. For this tree, the cause was adding the new method `score(::Char)` in `BlackjackFacecards`.

!!! note
    A tree with no cause indicates that the cause occurred before you turned on snooping.

Each *cause* is associated with one or more *victims* of invalidation, a list here named `mt_backedges`. Let's extract the final (and in this case, only) victim:

```@repl tutorial-invalidations
sig, victim = tree.mt_backedges[end];
```

!!! note
    `mt_backedges` stands for "MethodTable backedges." In other cases you may see a second kind of invalidation, just called `backedges`. With these, there is no `sig`, and so you'll use just `victim = tree.backedges[i]`. For those curious about the reasons for these two kinds of invalidation, see [Invalidation classes](@ref).

First let's look at the the problematic method `sig`nature:

```@repl tutorial-invalidations
sig
```

This is a type-tuple, i.e., `Tuple{typeof(f), typesof(args)...}`. We see that `score` was called on an object of (inferred) type `Any`. **Calling a function with unknown argument types makes code vulnerable to invalidation, and insertion of the new `score` method "exploited" this vulnerability.**

`victim` shows which compiled code got invalidated:

```@repl tutorial-invalidations
victim
```

But this is not the full extent of what got invalidated:

```@repl tutorial-invalidations
print_tree(victim)
```

Invalidations propagate throughout entire call trees, here up to `playgame()`: anything that calls code that may no longer be correct is itself at risk for being incorrect.
In general, victims with lots of "children" deserve the greatest attention.

While `print_tree` can be useful, Cthulhu's `ascend` is a far more powerful tool for gaining deeper insight:

```julia
julia> using Cthulhu

julia> ascend(victim)
Choose a call for analysis (q to quit):
 >   tallyscores(::Vector{Any})
       playgame()
```

This is an interactive REPL-menu, described more completely (via text and video) at [ascend](https://github.com/JuliaDebug/Cthulhu.jl?tab=readme-ov-file#usage-ascend).

There are quite a few other tools for working with `invs` and `trees`, see the [Reference](@ref). If your list of invalidations is dauntingly large, you may be interested in [`precompile_blockers`](@ref).

### Why the invalidations occur

`tallyscores` and `playgame` were compiled in `Blackjack`, a "world" where the `score` method defined in `BlackjackFacecards` does not yet exist. When you load the `BlackjackFacecards` package, Julia must ask itself: now that this new `score` method exists, am I certain that I would compile `tallyscores` the same way? If the answer is "no," Julia invalidates the old compiled code, and compiles a fresh version with full awareness of the new `score` method in `BlackjackFacecards`.

Why would the compilation of `tallyscores` change? Evidently, `cards` is a `Vector{Any}`, and this means that `tallyscores` can't guess what kind of object `card` might be, and thus it can't guess what kind of objects are passed into `score`. The crux of the invalidation is thus:
- when `Blackjack` is compiled, inference does not know which `score` method will be called. However, at the time of compilation the only `score` method is for `Int`. Thus Julia will reason that anything that isn't an `Int` is going to trigger an error anyway, and so you might as well optimize `tallyscore` expecting all cards to be `Int`s.
- however, when `BlackjackFacecards` is loaded, suddenly there are two `score` methods supporting both `Int` and `Char`. Now Julia's guess that all `cards` will probably be `Int`s doesn't seem so likely to be true, and thus `tallyscores` should be recompiled.

Thus, invalidations arise from optimization based on what methods and types are "in the world" at the time of compilation (sometimes called *world-splitting*). This form of optimization can have performance benefits, but it also leaves your code vulnerable to invalidation.

### Fixing invalidations

In broad strokes, there are three ways to prevent invalidation.

#### Method 1: defer compilation until the full world is known

The first and simplest technique is to ensure that the full range of possibilties (the entire "world of code") is present before any compilation occurs. In this case, probably the best approach would be to merge the `BlackjackFacecards` package into `Blackjack` itself. Or, if you are a maintainer of the "Blackjack ecosystem" and have reasons for thinking that keeping the packages separate makes sense, you could alternatively move the `PrecompileTools` workload to `BlackjackFacecards`. Either approach should prevent the invalidations from occuring.

#### Method 2: improve inferability

The second way to prevent invalidations is to improve the inferability of the victim(s). This approach is often applicable to `mt_backedges` invalidations,  but it can sometimes fix `backedges` invalidations too. [Invalidation classes](@ref) explains the differences in detail and why inference failures tend to be affiliated with `mt_backedges` invalidations.

In our blackjack example, if `Int` and `Char` really are the only possible kinds of cards, then in `playgame` it would be better to declare

```julia
myhand = Union{Int,Char}[]
```
and similarly for `deck` itself. That untyped `[]` is what makes `myhand` (and thus `cards`, when passed to `tallyscore`) a `Vector{Any}`, and the possibilities for `card` are endless. By constraining the possible types, we allow inference to know more clearly what methods might be called. More tips on fixing invalidations through improving inference can be found in [Techniques for fixing inference problems](@ref).

In this particular case, just annotating `Union{Int,Char}[]` isn't sufficient on its own, because the `score` method for `Char` doesn't yet exist, so Julia doesn't know what to call. However, in most real-world cases this change alone would be sufficient: usually all the needed methods exist, it's just a question of reassuring Julia that no other options are even possible.

!!! note
    This fix leverages [union-splitting](https://julialang.org/blog/2018/08/union-splitting/), which is conceptually related to "world-splitting." However, union-splitting is far more effective at fixing inference problems, as it guarantees that no other possibilities will *ever* exist, no matter how many other methods get defined.

!!! tip
    Many vulnerabilities can be fixed by improving inference. In complex code, it's easy to unwittingly write things in ways that defeat Julia's type inference. Tools that help you discover inference problems, like SnoopCompile and [JET](@ref), help you discover these unwitting "mistakes."

While in real life it's usually a bad idea to "blame the victim," it's typically the right attitude for fixing invalidations. Keep in mind, though, that the source of the problem may not be the immediate victim: in this case, it was a poor container choice in `playgame` that put `tallyscore` in the bad position of having to operate on a `Vector{Any}`.

Improving inferability is probably the most broadly-applicable technique, and when applicable it usually gives the best outcomes: not only is your code more resistant to invalidation, but it's likely faster and compiles to smaller binaries. However, of the three approaches it is also the one that requires the deepest understanding of Julia's type system, and thus may be difficult for some coders to use.

There are cases where there is no good way to make the code inferable, in which case other strategies are needed.

#### Method 3: disable Julia's speculative optimization

The third option is to prevent Julia's speculative optimization: one could replace `score(card)` with `invokelatest(score, card)`:

```julia
function tallyscores(cards)
    s = 0
    for card in cards
        s += invokelatest(score, card)
    end
    return s
end
```

This forces Julia to always look up the appropriate method of `score` while the code is running, and thus prevents the speculative optimizations that leave the code vulnerable to invalidation. However, the cost is that your code may run somewhat more slowly, particularly here where the call is inside a loop.

If you plan to define at least two `score` methods, another way to turn off this optimization would be to declare

```julia
Base.Experimental.@max_methods 1 function score end
```

before defining any `score` methods. You can read the documentation on `@max_methods` to learn more about how it works.

!!! tip
    Most of us learn best by doing. Try at least one of these methods of fixing the invalidation, and use SnoopCompile to verify that it works.

### Undoing the damage from invalidations

If you can't prevent the invalidation, an alternative approach is to recompile the invalidated code. For example, one could repeat the precompile workload from `Blackjack` in `BlackjackFacecards`. While this will mean that the whole "stack" will be compiled twice and cached twice (which is wasteful), it should be effective in reducing latency for users.

PrecompileTools also has a `@recompile_invalidations`. This isn't generally recommended for use in package (you can end up with long compile times for things you don't need), but it can be useful in personal "Startup packages" where you want to reduce latency for a particular project you're working on. See the PrecompileTools documentation for details.

```@repl tutorial-invalidations
Pkg.activate(oldproj)   # hide
```
