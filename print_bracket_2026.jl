using MarchMadnessOptimizer

# Suppress solver noise by redirecting stdout during optimization
bracket, teams, games = redirect_stdout(devnull) do
    run_tournament_optimization(
        filepath="data/kenpom_2026.csv",
        apply_upset_constraints=true,
        upset_prop=0.5
    )
end

# --- Printable bracket cheat sheet ---

function team_str(teams, id)
    t = teams[id]
    "$(t.seed) $(t.name)"
end

function upset_marker(teams, winner_id, loser_id)
    w = teams[winner_id]
    l = teams[loser_id]
    w.seed > l.seed ? "  *** UPSET ***" : ""
end

region_r1 = Dict("E" => 1:8, "W" => 9:16, "MW" => 17:24, "S" => 25:32)
region_names = Dict("E"=>"EAST", "W"=>"WEST", "MW"=>"MIDWEST", "S"=>"SOUTH")
round_names = ["ROUND OF 64", "ROUND OF 32", "SWEET 16", "ELITE 8"]

println("\n")
println("=" ^ 62)
println("   2026 NCAA TOURNAMENT BRACKET — OPTIMAL PICKS (KenPom)")
println("   Expected Score: $(round(bracket.score, digits=2))")
println("=" ^ 62)

for region in ["E", "W", "MW", "S"]
    println("\n")
    println("┌" * "─" ^ 60 * "┐")
    println("│" * lpad("$(region_names[region]) REGION", 36) * " " ^ 24 * "│")
    println("└" * "─" ^ 60 * "┘")

    # Collect games for this region by round
    # Round 1: 8 games per region
    r1_start = first(region_r1[region])

    # Trace the bracket tree for this region
    # Round 1 game IDs
    r1 = collect(region_r1[region])

    # Round 2: find games fed by round 1 games
    r2 = sort(unique([games[g].next_game for g in r1]))

    # Sweet 16: fed by round 2
    r3 = sort(unique([games[g].next_game for g in r2]))

    # Elite 8: fed by Sweet 16
    r4 = sort(unique([games[g].next_game for g in r3]))

    # Print Round 1
    println("\n  $(round_names[1]):")
    for g in r1
        game = games[g]
        t1, t2 = game.team1_id, game.team2_id
        w = bracket.winners[g]
        l = (w == t1) ? t2 : t1
        marker = upset_marker(teams, w, l)
        println("    $(rpad(team_str(teams, t1), 25)) vs  $(rpad(team_str(teams, t2), 22))→  $(team_str(teams, w))$marker")
    end

    # Print Round 2
    println("\n  $(round_names[2]):")
    for g in r2
        # Find the two feeder games
        feeders = sort([fg for fg in 1:(g-1) if games[fg].next_game == g])
        t1 = bracket.winners[feeders[1]]
        t2 = bracket.winners[feeders[2]]
        w = bracket.winners[g]
        l = (w == t1) ? t2 : t1
        marker = upset_marker(teams, w, l)
        println("    $(rpad(team_str(teams, t1), 25)) vs  $(rpad(team_str(teams, t2), 22))→  $(team_str(teams, w))$marker")
    end

    # Print Sweet 16
    println("\n  $(round_names[3]):")
    for g in r3
        feeders = sort([fg for fg in 1:(g-1) if games[fg].next_game == g])
        t1 = bracket.winners[feeders[1]]
        t2 = bracket.winners[feeders[2]]
        w = bracket.winners[g]
        l = (w == t1) ? t2 : t1
        marker = upset_marker(teams, w, l)
        println("    $(rpad(team_str(teams, t1), 25)) vs  $(rpad(team_str(teams, t2), 22))→  $(team_str(teams, w))$marker")
    end

    # Print Elite 8
    println("\n  $(round_names[4]):")
    for g in r4
        feeders = sort([fg for fg in 1:(g-1) if games[fg].next_game == g])
        t1 = bracket.winners[feeders[1]]
        t2 = bracket.winners[feeders[2]]
        w = bracket.winners[g]
        l = (w == t1) ? t2 : t1
        marker = upset_marker(teams, w, l)
        println("    $(rpad(team_str(teams, t1), 25)) vs  $(rpad(team_str(teams, t2), 22))→  $(team_str(teams, w))$marker")
    end

    e8_winner = bracket.winners[r4[1]]
    println("\n  ★  $(team_str(teams, e8_winner))  →  FINAL FOUR")
end

# Final Four
println("\n")
println("┌" * "─" ^ 60 * "┐")
println("│" * lpad("FINAL FOUR", 36) * " " ^ 24 * "│")
println("└" * "─" ^ 60 * "┘")

# Semifinal 1 (game 61): E vs MW
region_full = Dict("E"=>"East","W"=>"West","MW"=>"Midwest","S"=>"South")
sf1_regions = [games[g].region for g in 57:60 if games[g].next_game == 61]
sf2_regions = [games[g].region for g in 57:60 if games[g].next_game == 62]
sf1_label = join([region_full[r] for r in sf1_regions], " vs ")
sf2_label = join([region_full[r] for r in sf2_regions], " vs ")

println("\n  SEMIFINAL 1 ($sf1_label):")
ff1_feeders = sort([g for g in 1:62 if games[g].next_game == 61])
t1 = bracket.winners[ff1_feeders[1]]
t2 = bracket.winners[ff1_feeders[2]]
w61 = bracket.winners[61]
l61 = (w61 == t1) ? t2 : t1
marker = upset_marker(teams, w61, l61)
println("    $(rpad(team_str(teams, t1), 25)) vs  $(rpad(team_str(teams, t2), 22))→  $(team_str(teams, w61))$marker")

# Semifinal 2 (game 62): W vs S
println("\n  SEMIFINAL 2 ($sf2_label):")
ff2_feeders = sort([g for g in 1:62 if games[g].next_game == 62])
t1 = bracket.winners[ff2_feeders[1]]
t2 = bracket.winners[ff2_feeders[2]]
w62 = bracket.winners[62]
l62 = (w62 == t1) ? t2 : t1
marker = upset_marker(teams, w62, l62)
println("    $(rpad(team_str(teams, t1), 25)) vs  $(rpad(team_str(teams, t2), 22))→  $(team_str(teams, w62))$marker")

# Championship (game 63)
println("\n")
println("┌" * "─" ^ 60 * "┐")
println("│" * lpad("CHAMPIONSHIP", 36) * " " ^ 24 * "│")
println("└" * "─" ^ 60 * "┘")
t1 = bracket.winners[61]
t2 = bracket.winners[62]
w63 = bracket.winners[63]
l63 = (w63 == t1) ? t2 : t1
marker = upset_marker(teams, w63, l63)
println("\n    $(rpad(team_str(teams, t1), 25)) vs  $(rpad(team_str(teams, t2), 22))→  $(team_str(teams, w63))$marker")

println("\n" * "=" ^ 62)
println("   ★ ★ ★   CHAMPION:  $(team_str(teams, w63))   ★ ★ ★")
println("=" ^ 62)
println()
