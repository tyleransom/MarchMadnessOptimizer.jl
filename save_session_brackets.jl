using MarchMadnessOptimizer

# ── helpers ──────────────────────────────────────────────────────────────────

function team_str(teams, id)
    t = teams[id]
    "$(t.seed) $(t.name)"
end

function upset_marker(teams, winner_id, loser_id)
    teams[winner_id].seed > teams[loser_id].seed ? "  *** UPSET ***" : ""
end

function write_bracket_file(path, title, subtitle, bracket, teams, games)
    open(path, "w") do io
        println(io)
        println(io, "=" ^ 62)
        println(io, "   $title")
        println(io, "   $subtitle")
        println(io, "   Expected Score: $(round(bracket.score, digits=2))")
        println(io, "=" ^ 62)

        region_r1   = Dict("E" => 1:8, "W" => 9:16, "MW" => 17:24, "S" => 25:32)
        region_names = Dict("E"=>"EAST", "W"=>"WEST", "MW"=>"MIDWEST", "S"=>"SOUTH")
        round_labels = ["ROUND OF 64", "ROUND OF 32", "SWEET 16", "ELITE 8"]

        for region in ["E", "W", "MW", "S"]
            println(io)
            println(io, "┌" * "─"^60 * "┐")
            println(io, "│" * lpad("$(region_names[region]) REGION", 36) * " "^24 * "│")
            println(io, "└" * "─"^60 * "┘")

            r1 = collect(region_r1[region])
            r2 = sort(unique([games[g].next_game for g in r1]))
            r3 = sort(unique([games[g].next_game for g in r2]))
            r4 = sort(unique([games[g].next_game for g in r3]))

            # Round of 64
            println(io, "\n  $(round_labels[1]):")
            for g in r1
                game = games[g]
                t1, t2 = game.team1_id, game.team2_id
                w = bracket.winners[g]
                l = (w == t1) ? t2 : t1
                mk = upset_marker(teams, w, l)
                println(io, "    $(rpad(team_str(teams,t1),25)) vs  $(rpad(team_str(teams,t2),22))→  $(team_str(teams,w))$mk")
            end

            # Rounds 2–4
            for (rnd, games_in_round) in zip(2:4, [r2, r3, r4])
                println(io, "\n  $(round_labels[rnd]):")
                for g in games_in_round
                    feeders = sort([fg for fg in 1:(g-1) if games[fg].next_game == g])
                    t1 = bracket.winners[feeders[1]]
                    t2 = bracket.winners[feeders[2]]
                    w  = bracket.winners[g]
                    l  = (w == t1) ? t2 : t1
                    mk = upset_marker(teams, w, l)
                    println(io, "    $(rpad(team_str(teams,t1),25)) vs  $(rpad(team_str(teams,t2),22))→  $(team_str(teams,w))$mk")
                end
            end

            e8_winner = bracket.winners[r4[1]]
            println(io, "\n  ★  $(team_str(teams, e8_winner))  →  FINAL FOUR")
        end

        # Final Four
        println(io)
        println(io, "┌" * "─"^60 * "┐")
        println(io, "│" * lpad("FINAL FOUR", 36) * " "^24 * "│")
        println(io, "└" * "─"^60 * "┘")

        println(io, "\n  SEMIFINAL 1 (East vs Midwest):")
        ff1 = sort([g for g in 1:62 if games[g].next_game == 61])
        t1, t2 = bracket.winners[ff1[1]], bracket.winners[ff1[2]]
        w61 = bracket.winners[61]; l61 = (w61==t1) ? t2 : t1
        println(io, "    $(rpad(team_str(teams,t1),25)) vs  $(rpad(team_str(teams,t2),22))→  $(team_str(teams,w61))$(upset_marker(teams,w61,l61))")

        println(io, "\n  SEMIFINAL 2 (West vs South):")
        ff2 = sort([g for g in 1:62 if games[g].next_game == 62])
        t1, t2 = bracket.winners[ff2[1]], bracket.winners[ff2[2]]
        w62 = bracket.winners[62]; l62 = (w62==t1) ? t2 : t1
        println(io, "    $(rpad(team_str(teams,t1),25)) vs  $(rpad(team_str(teams,t2),22))→  $(team_str(teams,w62))$(upset_marker(teams,w62,l62))")

        # Championship
        println(io)
        println(io, "┌" * "─"^60 * "┐")
        println(io, "│" * lpad("CHAMPIONSHIP", 36) * " "^24 * "│")
        println(io, "└" * "─"^60 * "┘")
        t1, t2 = bracket.winners[61], bracket.winners[62]
        w63 = bracket.winners[63]; l63 = (w63==t1) ? t2 : t1
        println(io, "\n    $(rpad(team_str(teams,t1),25)) vs  $(rpad(team_str(teams,t2),22))→  $(team_str(teams,w63))$(upset_marker(teams,w63,l63))")

        println(io, "\n" * "="^62)
        println(io, "   ★ ★ ★   CHAMPION:  $(team_str(teams, w63))   ★ ★ ★")
        println(io, "="^62)
        println(io)
    end
    println("Saved → $path")
end

# ── run optimizations (suppress solver output) ────────────────────────────────

println("Running Bracket 1: Illinois wins it all…")
b1, t1, g1 = redirect_stdout(devnull) do
    run_tournament_optimization(
        filepath="data/kenpom_2026.csv",
        apply_upset_constraints=true,
        upset_prop=0.5,
        championship_winner=("S", 3),
        max_advancements=Dict("BYU" => 1)
    )
end

println("Running Bracket 2: Purdue wins it all…")
b2, t2, g2 = redirect_stdout(devnull) do
    run_tournament_optimization(
        filepath="data/kenpom_2026.csv",
        apply_upset_constraints=true,
        upset_prop=0.5,
        championship_winner=("W", 2),
        max_advancements=Dict("BYU" => 1)
    )
end

println("Running Bracket 3: Upsets Lite…")
b3, t3, g3 = redirect_stdout(devnull) do
    run_tournament_optimization(
        filepath="data/kenpom_2026.csv",
        apply_upset_constraints=true,
        upset_prop=1/3,
        upset_mode=:per_region
    )
end

# ── write files ───────────────────────────────────────────────────────────────

write_bracket_file(
    "output/bracket_2026_illinois_champ.txt",
    "2026 NCAA TOURNAMENT — ILLINOIS WINS IT ALL",
    "Constraints: 50% upsets per round · BYU exits round 1 or 2",
    b1, t1, g1
)

write_bracket_file(
    "output/bracket_2026_purdue_champ.txt",
    "2026 NCAA TOURNAMENT — PURDUE WINS IT ALL",
    "Constraints: 50% upsets per round · BYU exits round 1 or 2",
    b2, t2, g2
)

write_bracket_file(
    "output/bracket_2026_upsets_lite.txt",
    "2026 NCAA TOURNAMENT — UPSETS LITE (KenPom Optimal)",
    "Constraints: 5 upsets per region · 1 upset in Final Four",
    b3, t3, g3
)
