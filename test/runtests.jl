using Test
using MarchMadnessOptimizer

const DATA_FILE = joinpath(@__DIR__, "..", "data", "fivethirtyeight_2025.txt")

@testset "MarchMadnessOptimizer" begin

    @testset "Data loading" begin
        teams, probs = load_teams_and_probs(DATA_FILE)
        @test length(teams) == 64
        @test all(haskey(probs, (id, r)) for id in 1:64, r in 1:6)
        # Probabilities should be between 0 and 1
        @test all(0.0 <= probs[(id, r)] <= 1.0 for id in 1:64, r in 1:6)
    end

    @testset "Tournament structure" begin
        teams = initialize_teams()
        games = initialize_tournament_structure(teams)
        @test length(games) == 63
        # Rounds 1-6 have the right number of games
        for r in 1:6
            count = sum(1 for (_, g) in games if g.round == r)
            @test count == MarchMadnessOptimizer.GAMES_PER_ROUND[r]
        end
    end

    @testset "resolve_team_id" begin
        teams, _ = load_teams_and_probs(DATA_FILE)
        # By name
        duke_id = resolve_team_id(teams, "Duke")
        @test teams[duke_id].name == "Duke"
        @test teams[duke_id].seed == 1
        # By region+seed code
        e1_id = resolve_team_id(teams, "E1")
        @test teams[e1_id].region == "E"
        @test teams[e1_id].seed == 1
        @test duke_id == e1_id
        # Case-insensitive name lookup
        @test resolve_team_id(teams, "duke") == duke_id
        # Invalid name should error
        @test_throws ErrorException resolve_team_id(teams, "Nonexistent University")
    end

    @testset "Basic optimization (no constraints)" begin
        bracket, teams, games = run_tournament_optimization(
            filepath=DATA_FILE,
            apply_upset_constraints=false
        )
        @test length(bracket.winners) == 63
        @test bracket.score > 0
        # Every game has a winner
        @test all(haskey(bracket.winners, g) for g in 1:63)
    end

    @testset "Upset constraints (per round, 50%)" begin
        bracket, teams, games = run_tournament_optimization(
            filepath=DATA_FILE,
            apply_upset_constraints=true,
            upset_prop=0.5
        )
        @test bracket.score > 0
        # Each round has at least ceil(games * 0.5) upsets
        for r in 1:6
            min_required = ceil(Int, MarchMadnessOptimizer.GAMES_PER_ROUND[r] * 0.5)
            @test bracket.upsets[r] >= min_required
        end
    end

    @testset "Upset constraints (per region, 1/3)" begin
        bracket, teams, games = run_tournament_optimization(
            filepath=DATA_FILE,
            apply_upset_constraints=true,
            upset_prop=1/3,
            upset_mode=:per_region
        )
        @test bracket.score > 0
        # Each region should have at least ceil(15 * 1/3) = 5 upsets
        for region in ["E", "W", "MW", "S"]
            region_games = [g for g in 1:60 if games[g].region == region]
            @test length(region_games) == 15
            region_upsets = count(g -> begin
                winner = teams[bracket.winners[g]]
                r = games[g].round
                if r == 1
                    game = games[g]
                    t1, t2 = teams[game.team1_id], teams[game.team2_id]
                    (t1.seed < t2.seed && bracket.winners[g] == t2.id) ||
                    (t1.seed > t2.seed && bracket.winners[g] == t1.id)
                else
                    # For later rounds, check if winner has higher seed than loser
                    prev_games = filter(pg -> games[pg].next_game == g, 1:(g-1))
                    if length(prev_games) == 2
                        t1 = teams[bracket.winners[prev_games[1]]]
                        t2 = teams[bracket.winners[prev_games[2]]]
                        (t1.seed < t2.seed && bracket.winners[g] == t2.id) ||
                        (t1.seed > t2.seed && bracket.winners[g] == t1.id)
                    else
                        false
                    end
                end
            end, region_games)
            @test region_upsets >= 5  # ceil(15 * 1/3) = 5
        end
        # FF games should have at least 1 upset
        total_upsets = sum(values(bracket.upsets))
        @test total_upsets >= 21  # 4 regions * 5 + 1 FF = 21
    end

    @testset "Forced advancements" begin
        bracket, teams, games = run_tournament_optimization(
            filepath=DATA_FILE,
            apply_upset_constraints=true,
            upset_prop=0.5,
            forced_advancements=Dict("BYU" => 3)  # Sweet 16
        )
        byu_id = resolve_team_id(teams, "BYU")
        byu_wins = [g for (g, t) in bracket.winners if t == byu_id]
        # BYU must win at least 2 games (rounds 1 and 2) to reach Sweet 16
        @test length(byu_wins) >= 2
        # Check BYU won in round 1 and round 2
        byu_rounds = sort([games[g].round for g in byu_wins])
        @test 1 in byu_rounds
        @test 2 in byu_rounds
    end

    @testset "Forced advancements (multiple teams)" begin
        bracket, teams, games = run_tournament_optimization(
            filepath=DATA_FILE,
            apply_upset_constraints=true,
            upset_prop=0.5,
            forced_advancements=Dict("BYU" => 3, "Duke" => 5)  # BYU to S16, Duke to FF
        )
        duke_id = resolve_team_id(teams, "Duke")
        duke_wins = [g for (g, t) in bracket.winners if t == duke_id]
        duke_rounds = sort([games[g].round for g in duke_wins])
        # Duke must reach Final Four (win through round 4)
        @test all(r in duke_rounds for r in 1:4)
    end

    @testset "Cinderella mode (per round, 50%)" begin
        bracket, teams, games = run_tournament_optimization(
            filepath=DATA_FILE,
            apply_upset_constraints=true,
            upset_prop=0.5,
            cinderella_mode=true
        )
        @test bracket.score > 0
        @test !isempty(bracket.cinderellas)
        # Each round has enough cinderellas
        for r in 1:6
            min_required = ceil(Int, MarchMadnessOptimizer.GAMES_PER_ROUND[r] * 0.5)
            @test bracket.cinderellas[r] >= min_required
        end
        # Verify cinderella thresholds
        thresholds = MarchMadnessOptimizer.CINDERELLA_THRESHOLDS
        for r in 1:6
            start_game = r == 1 ? 1 : sum(MarchMadnessOptimizer.GAMES_PER_ROUND[1:(r-1)]) + 1
            end_game = sum(MarchMadnessOptimizer.GAMES_PER_ROUND[1:r])
            cind_count = 0
            for g in start_game:end_game
                winner = teams[bracket.winners[g]]
                if winner.seed > thresholds[r]
                    cind_count += 1
                end
            end
            @test cind_count == bracket.cinderellas[r]
        end
    end

    @testset "Cinderella mode gives more freedom than upsets" begin
        # Cinderella constraint is weaker (e.g. 5 over 13 is cinderella but not upset)
        # so the optimal score should be >= the upset-constrained score
        b_upset, _, _ = run_tournament_optimization(
            filepath=DATA_FILE,
            apply_upset_constraints=true,
            upset_prop=0.5,
            cinderella_mode=false
        )
        b_cind, _, _ = run_tournament_optimization(
            filepath=DATA_FILE,
            apply_upset_constraints=true,
            upset_prop=0.5,
            cinderella_mode=true
        )
        @test b_cind.score >= b_upset.score - 0.01  # allow tiny numerical tolerance
    end

    @testset "Custom Final Four with new features" begin
        bracket = run_with_custom_final_four(
            filepath=DATA_FILE,
            final_four_teams=Dict("E"=>1, "MW"=>2, "S"=>3, "W"=>10),
            apply_upset_constraints=true,
            upset_prop=0.5,
            forced_advancements=Dict("BYU" => 2)  # BYU to round 2
        )
        @test bracket.score > 0
        teams_lookup, _ = load_teams_and_probs(DATA_FILE)
        byu_id = resolve_team_id(teams_lookup, "BYU")
        byu_wins = [g for (g, tid) in bracket.winners if tid == byu_id]
        @test length(byu_wins) >= 1  # BYU must win at least round 1
    end

end
