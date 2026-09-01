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
