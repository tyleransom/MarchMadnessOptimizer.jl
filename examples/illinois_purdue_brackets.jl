using MarchMadnessOptimizer

filepath = joinpath(@__DIR__, "..", "data", "kenpom_2026.csv")

println("\n" * "="^60)
println("BRACKET 1: Illinois wins it all (BYU exits round 1 or 2)")
println("="^60)
bracket1, teams1, games1 = run_tournament_optimization(
    filepath=filepath,
    apply_upset_constraints=true,
    upset_prop=0.5,
    championship_winner=("S", 3),
    max_advancements=Dict("BYU" => 1)
)

println("\n" * "="^60)
println("BRACKET 2: Purdue wins it all (BYU exits round 1 or 2)")
println("="^60)
bracket2, teams2, games2 = run_tournament_optimization(
    filepath=filepath,
    apply_upset_constraints=true,
    upset_prop=0.5,
    championship_winner=("W", 2),
    max_advancements=Dict("BYU" => 1)
)
