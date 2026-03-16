# Optional: Add this at the top if you want the example to be self-contained
# This ensures the package is loaded even if users run just this file
if !isinteractive()
    import Pkg
    Pkg.activate(@__DIR__)  # Activate the environment of the examples directory
    Pkg.develop(path=dirname(@__DIR__))  # Develop the parent package
end

using MarchMadnessOptimizer

# Upset proportion for the tournament
upset_prop = 0.5

# Define the required Final Four teams
final_four = Dict(
    "E" => 1,   # 1 seed from East region
    "MW" => 8,  # 8 seed from Midwest region
    "S" => 3,   # 3 seed from South region
    "W" => 10   # 10 seed from West region
)

# Define championship matchup (winner, runner-up)
championship = (("MW", 8), ("S", 3))

# First, verify the tournament structure
teams = initialize_teams()
games = initialize_tournament_structure(teams)

# Print the tournament structure for verification
println("Tournament Structure:")
println("Elite 8 games:")
for g in 57:60
    region = games[g].region
    println("  Game $g: Region $region")
end

println("\nFinal Four Semifinals:")
println("  Game 61: Regions $(games[61].region)")
println("  Game 62: Regions $(games[62].region)")

println("\nChampionship:")
println("  Game 63: $(games[63].region)")

# Make sure our regions match what's in the code
println("\nAll regions in the tournament:")
regions = unique([team.region for (_, team) in teams])
println("  $regions")

# Run with just the Final Four constraints
println("\n----- Running with Final Four constraints only -----")
try
    bracket = run_with_custom_final_four(
        final_four_teams=final_four, 
        apply_upset_constraints=true, 
        upset_prop=upset_prop
    )
    
    # Print the resulting Final Four
    println("\nResulting Final Four:")
    for g in 57:60
        winner_id = bracket.winners[g]
        winner = teams[winner_id]
        println("  $(winner.region)$(winner.seed)")
    end
    
    # Print championship matchup
    semifinal1_winner = bracket.winners[61]
    semifinal2_winner = bracket.winners[62]
    championship_winner = bracket.winners[63]
    
    println("\nChampionship matchup:")
    println("  $(teams[semifinal1_winner].region)$(teams[semifinal1_winner].seed) vs $(teams[semifinal2_winner].region)$(teams[semifinal2_winner].seed)")
    println("  Winner: $(teams[championship_winner].region)$(teams[championship_winner].seed)")
catch e
    println("Error running with Final Four constraints: $e")
end

# Run with both Final Four and championship constraints
println("\n----- Running with Final Four and Championship constraints -----")
try
    bracket = run_with_custom_final_four(
        final_four_teams=final_four, 
        championship_matchup=championship,
        apply_upset_constraints=true, 
        upset_prop=upset_prop
    )
    
    # Print the resulting Final Four
    println("\nResulting Final Four:")
    for g in 57:60
        winner_id = bracket.winners[g]
        winner = teams[winner_id]
        println("  $(winner.region)$(winner.seed)")
    end
    
    # Print championship matchup
    semifinal1_winner = bracket.winners[61]
    semifinal2_winner = bracket.winners[62]
    championship_winner = bracket.winners[63]
    
    println("\nChampionship matchup:")
    println("  $(teams[semifinal1_winner].region)$(teams[semifinal1_winner].seed) vs $(teams[semifinal2_winner].region)$(teams[semifinal2_winner].seed)")
    println("  Winner: $(teams[championship_winner].region)$(teams[championship_winner].seed)")
    
    # Print the full bracket
    print_bracket_with_upsets(bracket, teams, games, upset_prop)
catch e
    println("Error running with Final Four and Championship constraints: $e")
end
