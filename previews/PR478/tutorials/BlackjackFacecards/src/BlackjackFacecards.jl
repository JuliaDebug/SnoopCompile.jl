module BlackjackFacecards

using Blackjack

# Add a new `score` method:
Blackjack.score(card::Char) = card ∈ ('J', 'Q', 'K') ? 10 :
                              card == 'A' ? 11 : error(card, " not known")

end
