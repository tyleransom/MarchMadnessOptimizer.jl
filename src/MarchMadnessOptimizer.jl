module MarchMadnessOptimizer
using Statistics, JuMP, GLPK

export initialize_teams, create_first_round_matchups, initialize_tournament_structure,
       create_realistic_advancement_probs, optimize_bracket, calculate_bracket_score,
       print_bracket, analyze_bracket, run_tournament_optimization,
       run_with_custom_final_four

# Constants for tournament structure
const NUM_TEAMS = 64
const NUM_ROUNDS = 6
const GAMES_PER_ROUND = [32, 16, 8, 4, 2, 1]
const TOTAL_GAMES = sum(GAMES_PER_ROUND)
const REGIONS = ["E", "W", "MW", "S"]
const TEAMS_PER_REGION = NUM_TEAMS ÷ 4

# Define a Team type with region and seed
struct Team
    id::Int         # Unique team ID (1-64)
    region::String  # Region (E, W, MW, S)
    seed::Int       # Seed within region (1-16)
    name::String    # Optional team name for display
end

# Define a Game type to represent each game in the tournament
struct Game
    id::Int         # Unique game ID (1-63)
    round::Int      # Tournament round (1-6)
    region::String  # Region or "FF" for Final Four/Championship
    team1_id::Int   # ID of first potential team (or 0 if determined by previous games)
    team2_id::Int   # ID of second potential team (or 0 if determined by previous games)
    next_game::Int  # ID of the next game for the winner (or 0 for championship)
end

# Define a type to represent a bracket (i.e., a tournament outcome)
struct Bracket
    winners::Dict{Int, Int}  # Map from game ID to winning team ID
    score::Float64           # Expected score of this bracket
    upsets::Dict{Int, Int}   # Number of upsets per round
end


"""
    initialize_teams()

Create the 64 teams with their regions and seeds.
Returns a dictionary mapping team ID to Team object.
"""
function initialize_teams()
    teams = Dict{Int, Team}()
    team_id = 1
    
    for region in REGIONS
        for seed in 1:16
            teams[team_id] = Team(team_id, region, seed, "$(region)$(seed)")
            team_id += 1
        end
    end
    
    return teams
end

"""
    create_first_round_matchups(teams)

Create the first round matchups for each region.
Returns a dictionary mapping game ID to a tuple of (team1_id, team2_id).
"""
function create_first_round_matchups(teams)
    matchups = Dict{Int, Tuple{Int, Int}}()
    game_id = 1
    
    # Standard first-round matchups by seed:
    # 1v16, 8v9, 5v12, 4v13, 6v11, 3v14, 7v10, 2v15
    seed_pairs = [(1, 16), (8, 9), (5, 12), (4, 13), (6, 11), (3, 14), (7, 10), (2, 15)]
    
    for region in REGIONS
        for (i, (seed1, seed2)) in enumerate(seed_pairs)
            # Find team IDs directly by iterating through the teams dictionary
            team1_id = 0
            team2_id = 0
            
            for (id, team) in teams
                if team.region == region && team.seed == seed1
                    team1_id = id
                end
                if team.region == region && team.seed == seed2
                    team2_id = id
                end
            end
            
            # Error checking to ensure we found both teams
            if team1_id == 0 || team2_id == 0
                error("Could not find teams for region $region with seeds $seed1 and $seed2")
            end
            
            matchups[game_id] = (team1_id, team2_id)
            game_id += 1
        end
    end
    
    return matchups
end

"""
    initialize_tournament_structure()

Initialize the full tournament structure with all games.
Returns a dictionary mapping game ID to Game object.
"""
function initialize_tournament_structure(teams)
    games = Dict{Int, Game}()
    first_round_matchups = create_first_round_matchups(teams)
    
    # Initialize first round games (32 games)
    for game_id in 1:32
        region_idx = (game_id - 1) ÷ 8 + 1
        region = REGIONS[region_idx]
        team1_id, team2_id = first_round_matchups[game_id]
        next_game = 32 + (game_id + 1) ÷ 2  # Connect to second round games
        
        games[game_id] = Game(game_id, 1, region, team1_id, team2_id, next_game)
    end
    
    # Initialize second round games (16 games)
    for game_id in 33:48
        region_idx = (game_id - 33) ÷ 4 + 1
        region = REGIONS[region_idx]
        next_game = 48 + (game_id - 32 + 1) ÷ 2  # Connect to Sweet 16 games
        
        games[game_id] = Game(game_id, 2, region, 0, 0, next_game)
    end
    
    # Initialize Sweet 16 games (8 games)
    for game_id in 49:56
        region_idx = (game_id - 49) ÷ 2 + 1
        region = REGIONS[region_idx]
        next_game = 56 + (game_id - 48 + 1) ÷ 2  # Connect to Elite 8 games
        
        games[game_id] = Game(game_id, 3, region, 0, 0, next_game)
    end
    
    # Initialize Elite 8 games (4 games)
    for game_id in 57:60
        region = REGIONS[game_id - 56]
        
        # Map regions to semifinals: E and MW to game 61, W and S to game 62
        if region == "E" || region == "MW"
            next_game = 61
        else # region == "W" || region == "S"
            next_game = 62
        end
        
        games[game_id] = Game(game_id, 4, region, 0, 0, next_game)
    end
    
    # Initialize Final Four games (2 games)
    # First semifinal: E vs MW
    games[61] = Game(61, 5, "FF", 0, 0, 63)
    # Second semifinal: W vs S
    games[62] = Game(62, 5, "FF", 0, 0, 63)
    
    # Initialize Championship game
    games[63] = Game(63, 6, "FF", 0, 0, 0)
    
    return games
end

"""
    create_realistic_advancement_probs(teams)

Create realistic advancement probabilities for each team in each round.
Returns a Dict mapping (team_id, round) to probability.
"""
function create_realistic_advancement_probs(teams)
    advancement_probs = Dict{Tuple{Int, Int}, Float64}()
    
    # Create base probabilities for each team based on seed
    base_probs = Dict{Int, Float64}()
    for (id, team) in teams
        # Simple seed-based model: probability inversely proportional to seed
        base_probs[id] = (17 - team.seed) / sum(17 - s for s in 1:16)
    end
    
    # Adjust probabilities for each round
    for round in 1:NUM_ROUNDS
        teams_advancing = GAMES_PER_ROUND[round]
        scaling_factor = teams_advancing / sum(values(base_probs))
        
        for (id, _) in teams
            # Probability decreases slightly in later rounds
            round_decay = 1.0 - 0.05 * (round - 1)
            advancement_probs[(id, round)] = base_probs[id] * scaling_factor * round_decay
        end
    end
    
    return advancement_probs
end

"""
    optimize_bracket(teams, games, advancement_probs; 
                    apply_upset_constraints=false,
                    final_four_teams=nothing,
                    championship_winner=nothing,
                    championship_runner_up=nothing)

Optimize the bracket to maximize expected score.
Parameters:
- teams: Dictionary mapping team ID to Team object
- games: Dictionary mapping game ID to Game object
- advancement_probs: Dictionary mapping (team_id, round) to probability
- apply_upset_constraints: If true, enforce minimum upsets per round
- final_four_teams: Dictionary mapping region to seed for Final Four teams
- championship_winner: Tuple (region, seed) for the championship winner
- championship_runner_up: Tuple (region, seed) for the championship runner-up

Returns a Bracket object with the winning teams for each game.
"""
function optimize_bracket(teams, games, advancement_probs; 
                         apply_upset_constraints=false,
                         final_four_teams=nothing,
                         championship_winner=nothing,
                         championship_runner_up=nothing)
    # Create optimization model
    model = Model(GLPK.Optimizer)
    set_optimizer_attribute(model, "msg_lev", GLPK.GLP_MSG_ALL)  # Full messaging
    
    # Decision variables: w[g,t] = 1 if team t wins game g
    @variable(model, w[1:TOTAL_GAMES, 1:NUM_TEAMS], Bin)
    
    # Helper variable: is_upset[g] = 1 if game g results in an upset
    @variable(model, is_upset[1:TOTAL_GAMES], Bin)
    
    # Helper variable: tracking which teams play in each game
    @variable(model, plays_in[1:TOTAL_GAMES, 1:NUM_TEAMS], Bin)
    
    # First round constraints - predetermined matchups
    for g in 1:GAMES_PER_ROUND[1]
        game = games[g]
        team1_id, team2_id = game.team1_id, game.team2_id
        
        # Only team1 or team2 can win game g
        @constraint(model, w[g, team1_id] + w[g, team2_id] == 1)
        
        # No other team can win this game
        for t in 1:NUM_TEAMS
            if t != team1_id && t != team2_id
                @constraint(model, w[g, t] == 0)
            end
        end
        
        # Mark these teams as playing in this game
        @constraint(model, plays_in[g, team1_id] == 1)
        @constraint(model, plays_in[g, team2_id] == 1)
        
        # Define upsets for round 1
        team1_seed = teams[team1_id].seed
        team2_seed = teams[team2_id].seed
        
        if team1_seed < team2_seed  # team1 is better seeded (lower number)
            @constraint(model, is_upset[g] == w[g, team2_id])
        elseif team1_seed > team2_seed  # team2 is better seeded
            @constraint(model, is_upset[g] == w[g, team1_id])
        else  # Equal seeds can't be an upset
            @constraint(model, is_upset[g] == 0)
        end
    end
    
    # Constraints for later rounds
    for r in 2:NUM_ROUNDS
        start_game = sum(GAMES_PER_ROUND[1:(r-1)]) + 1
        end_game = sum(GAMES_PER_ROUND[1:r])
        
        for g in start_game:end_game
            game = games[g]
            
            # Determine which games feed into this one
            prev_games = []
            for prev_g in 1:(start_game-1)
                if games[prev_g].next_game == g
                    push!(prev_games, prev_g)
                end
            end
            
            # A team can only win this game if it won one of the previous games
            for t in 1:NUM_TEAMS
                @constraint(model, w[g, t] <= sum(w[prev_g, t] for prev_g in prev_games))
                
                # A team plays in this game if it won one of the previous games
                @constraint(model, plays_in[g, t] == sum(w[prev_g, t] for prev_g in prev_games))
            end
            
            # Exactly one team wins this game
            @constraint(model, sum(w[g, t] for t in 1:NUM_TEAMS) == 1)
            
            # For tracking upsets in later rounds, we need additional variables
            # to ensure that is_upset[g] is properly connected to actual upsets
            
            # Store all potential upset conditions for this game
            upset_conditions = []
            
            # Create a binary variable for each potential matchup in this game
            for t1 in 1:NUM_TEAMS
                for t2 in (t1+1):NUM_TEAMS
                    # Skip if teams are from the same region in Final Four (they can't meet)
                    if r >= 5 && teams[t1].region == teams[t2].region
                        continue
                    end
                    
                    # matchup[t1,t2] = 1 if t1 and t2 play against each other in game g
                    matchup = @variable(model, binary=true)
                    
                    # Set matchup = 1 if both teams play in this game
                    @constraint(model, matchup <= plays_in[g, t1])
                    @constraint(model, matchup <= plays_in[g, t2])
                    @constraint(model, matchup >= plays_in[g, t1] + plays_in[g, t2] - 1)
                    
                    # Create upset condition variables for both possible outcomes
                    team1_seed = teams[t1].seed
                    team2_seed = teams[t2].seed
                    
                    if team1_seed < team2_seed  # t1 is better seeded
                        # If t2 wins, it's an upset
                        upset_var = @variable(model, binary=true)
                        
                        # upset_var is 1 if and only if this matchup occurs AND t2 wins
                        @constraint(model, upset_var <= matchup)
                        @constraint(model, upset_var <= w[g, t2])
                        @constraint(model, upset_var >= matchup + w[g, t2] - 1)
                        
                        # Add this to our list of potential upset conditions
                        push!(upset_conditions, upset_var)
                    elseif team1_seed > team2_seed  # t2 is better seeded
                        # If t1 wins, it's an upset
                        upset_var = @variable(model, binary=true)
                        
                        # upset_var is 1 if and only if this matchup occurs AND t1 wins
                        @constraint(model, upset_var <= matchup)
                        @constraint(model, upset_var <= w[g, t1])
                        @constraint(model, upset_var >= matchup + w[g, t1] - 1)
                        
                        # Add this to our list of potential upset conditions
                        push!(upset_conditions, upset_var)
                    end
                end
            end
            
            # is_upset[g] is 1 if and only if any of the upset conditions are true
            if !isempty(upset_conditions)
                # is_upset[g] is at least 1 if any upset condition is true
                @constraint(model, is_upset[g] <= sum(upset_conditions))
                
                # For each individual upset condition, if it's true, is_upset[g] must be 1
                for uc in upset_conditions
                    @constraint(model, is_upset[g] >= uc)
                end
            else
                # If no upset conditions exist for this game, is_upset[g] must be 0
                @constraint(model, is_upset[g] == 0)
            end
        end
    end
    
    # Add constraints for specific Final Four teams if requested
    if final_four_teams !== nothing
        # Teams that advance to Final Four are the winners of Elite 8 games (games 57-60)
        for (i, region) in enumerate(REGIONS)
            elite_8_game = 56 + i  # Games 57, 58, 59, 60 correspond to regions in order
            required_seed = final_four_teams[region]
            
            # Find the team ID for this region and seed
            team_id = 0
            for (id, team) in teams
                if team.region == region && team.seed == required_seed
                    team_id = id
                    break
                end
            end
            
            if team_id == 0
                error("Could not find team with region $region and seed $required_seed")
            end
            
            # Constrain this team to win its Elite 8 game
            @constraint(model, w[elite_8_game, team_id] == 1)
        end
    end
    
    # Add constraints for championship game if requested
    if championship_winner !== nothing && championship_runner_up !== nothing
        winner_region, winner_seed = championship_winner
        loser_region, loser_seed = championship_runner_up
        
        # Find team IDs for winner and runner-up
        winner_id = 0
        loser_id = 0
        
        for (id, team) in teams
            if team.region == winner_region && team.seed == winner_seed
                winner_id = id
            elseif team.region == loser_region && team.seed == loser_seed
                loser_id = id
            end
        end
        
        if winner_id == 0
            error("Could not find championship winner team with region $winner_region and seed $winner_seed")
        end
        if loser_id == 0
            error("Could not find championship runner-up team with region $loser_region and seed $loser_seed")
        end
        
        # Championship game is game 63
        championship_game = 63
        
        # Winner team wins the championship
        @constraint(model, w[championship_game, winner_id] == 1)
        
        # Both teams must play in the championship game
        # This means they must win their semifinal games
        
        # Determine which semifinal games these teams would be in
        # Assuming Final Four matchups: E vs MW and W vs S
        e_mw_semifinal = 61  # First semifinal: E vs MW
        w_s_semifinal = 62   # Second semifinal: W vs S
        
        # Constrain the winner and runner-up to win their respective semifinal games
        if winner_region == "E" || winner_region == "MW"
            @constraint(model, w[e_mw_semifinal, winner_id] == 1)
        else # winner is from W or S
            @constraint(model, w[w_s_semifinal, winner_id] == 1)
        end
        
        if loser_region == "E" || loser_region == "MW"
            @constraint(model, w[e_mw_semifinal, loser_id] == 1)
        else # loser is from W or S
            @constraint(model, w[w_s_semifinal, loser_id] == 1)
        end
    end
    
    # Apply upset constraints if requested
    if apply_upset_constraints
        # Modified to add more realistic upset distributions:
        # Higher upset percentages in early rounds, lower in later rounds
        upset_percentages = [0.5, 0.5, 0.4, 0.3, 0.25, 0.2]
        
        for r in 1:NUM_ROUNDS
            start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
            end_game = sum(GAMES_PER_ROUND[1:r])
            
            # At least the specified percentage of games in this round must be upsets
            min_upsets = ceil(Int, GAMES_PER_ROUND[r] * upset_percentages[r])
            @constraint(model, sum(is_upset[g] for g in start_game:end_game) >= min_upsets)
        end
    end
    
    # Objective: Maximize expected score
    # Using Fibonacci sequence for scoring: 1, 1, 2, 3, 5, 8
    fibonacci = [5, 8, 13, 21, 34, 55]
    
    # Calculate expected score for each round
    objective_expr = 0
    for r in 1:NUM_ROUNDS
        start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
        end_game = sum(GAMES_PER_ROUND[1:r])
        
        for g in start_game:end_game
            for t in 1:NUM_TEAMS
                # Points = Fibonacci value for round + seed value
                objective_expr += advancement_probs[(t, r)] * (fibonacci[r] + teams[t].seed) * w[g, t]
            end
        end
    end
    
    @objective(model, Max, objective_expr)
    
    # Solve the model
    println("Solving model", apply_upset_constraints ? " with" : " without", " upset constraints...")
    optimize!(model)
    
    # Extract and return the results
    if termination_status(model) == MOI.OPTIMAL
        winners = Dict{Int, Int}()
        upsets_by_round = Dict{Int, Int}()
        
        for r in 1:NUM_ROUNDS
            upsets_by_round[r] = 0
            start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
            end_game = sum(GAMES_PER_ROUND[1:r])
            
            for g in start_game:end_game
                for t in 1:NUM_TEAMS
                    if value(w[g, t]) > 0.5
                        winners[g] = t
                        if value(is_upset[g]) > 0.5
                            upsets_by_round[r] += 1
                        end
                        break
                    end
                end
            end
        end
        
        # Calculate actual score of the bracket
        score = calculate_bracket_score(winners, teams, advancement_probs)
        
        return Bracket(winners, score, upsets_by_round)
    else
        println("Status: ", termination_status(model))
        println("Reason: ", raw_status(model))
        error("No optimal solution found: $(termination_status(model))")
    end
end

"""
    calculate_bracket_score(winners, teams, advancement_probs)

Calculate the expected score of a bracket.
"""
function calculate_bracket_score(winners, teams, advancement_probs)
    fibonacci = [5, 8, 13, 21, 34, 55]
    score = 0.0
    
    for r in 1:NUM_ROUNDS
        start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
        end_game = sum(GAMES_PER_ROUND[1:r])
        
        for g in start_game:end_game
            team_id = winners[g]
            score += advancement_probs[(team_id, r)] * (fibonacci[r] + teams[team_id].seed)
        end
    end
    
    return score
end

"""
    print_bracket(bracket, teams, games)

Print the bracket in a readable format, showing all games and winners.
"""
function print_bracket(bracket, teams, games)
    println("\n===== TOURNAMENT BRACKET RESULTS =====\n")
    
    # Print each round
    round_names = ["First Round", "Second Round", "Sweet 16", "Elite 8", "Final Four", "Championship"]
    
    for r in 1:NUM_ROUNDS
        println(round_names[r] * ":")
        
        start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
        end_game = sum(GAMES_PER_ROUND[1:r])
        
        for g in start_game:end_game
            game = games[g]
            winner_id = bracket.winners[g]
            winner = teams[winner_id]
            
            # Determine the teams that played in this game
            if r == 1
                # First round has predetermined matchups
                team1_id, team2_id = game.team1_id, game.team2_id
                team1, team2 = teams[team1_id], teams[team2_id]
                
                is_upset = (team1.seed < team2.seed && winner_id == team2_id) || 
                           (team1.seed > team2.seed && winner_id == team1_id)
                
                upset_str = is_upset ? " (UPSET!)" : ""
                println("  Game $g: $(team1.region)$(team1.seed) vs $(team2.region)$(team2.seed) → $(winner.region)$(winner.seed) advances$upset_str")
            else
                # Later rounds need to look at previous winners
                prev_games = filter(prev_g -> games[prev_g].next_game == g, 1:(g-1))
                
                if length(prev_games) != 2
                    error("Expected 2 previous games for game $g, found $(length(prev_games))")
                end
                
                prev_game1, prev_game2 = prev_games
                team1_id, team2_id = bracket.winners[prev_game1], bracket.winners[prev_game2]
                team1, team2 = teams[team1_id], teams[team2_id]
                
                is_upset = (team1.seed < team2.seed && winner_id == team2_id) || 
                           (team1.seed > team2.seed && winner_id == team1_id)
                
                upset_str = is_upset ? " (UPSET!)" : ""
                
                if r == NUM_ROUNDS
                    println("  Game $g: $(team1.region)$(team1.seed) vs $(team2.region)$(team2.seed) → $(winner.region)$(winner.seed) CHAMPION$upset_str")
                else
                    println("  Game $g: $(team1.region)$(team1.seed) vs $(team2.region)$(team2.seed) → $(winner.region)$(winner.seed) advances$upset_str")
                end
            end
        end
        
        # Print upset statistics for this round
        upsets = bracket.upsets[r]
        games_in_round = GAMES_PER_ROUND[r]
        pct = upsets / games_in_round * 100
        min_upsets = ceil(Int, games_in_round * 0.5)
        
        println("\nUpsets in $(round_names[r]): $upsets/$games_in_round ($(round(pct, digits=1))%) [Minimum required: $min_upsets]")
        println()
    end
    
    # Print overall statistics
    total_upsets = sum(values(bracket.upsets))
    total_games = TOTAL_GAMES
    pct = total_upsets / total_games * 100
    
    println("Total Upsets: $total_upsets/$total_games ($(round(pct, digits=1))%)")
    println("Expected Score: $(round(bracket.score, digits=2))")
end

"""
    analyze_bracket(bracket, teams, games)

Provide additional analysis of the bracket.
"""
function analyze_bracket(bracket, teams, games)
    println("\n===== BRACKET ANALYSIS =====\n")
    
    # Count winners by seed
    winners_by_seed = Dict{Int, Int}()
    for seed in 1:16
        winners_by_seed[seed] = 0
    end
    
    for (g, winner_id) in bracket.winners
        winner = teams[winner_id]
        winners_by_seed[winner.seed] += 1
    end
    
    println("Advancement by Seed:")
    for seed in 1:16
        println("  Seed $seed: $(winners_by_seed[seed]) wins")
    end
    
    # Count winners by region
    winners_by_region = Dict{String, Int}()
    for region in REGIONS
        winners_by_region[region] = 0
    end
    winners_by_region["FF"] = 0  # Final Four
    
    for (g, winner_id) in bracket.winners
        round = games[g].round
        winner = teams[winner_id]
        
        if round <= 4
            winners_by_region[winner.region] += 1
        else
            winners_by_region["FF"] += 1
        end
    end
    
    println("\nAdvancement by Region:")
    for region in [REGIONS..., "FF"]
        println("  $region: $(winners_by_region[region]) wins")
    end
    
    # Final Four Teams
    println("\nFinal Four Teams:")
    for g in (sum(GAMES_PER_ROUND[1:4])-3):sum(GAMES_PER_ROUND[1:4])
        winner_id = bracket.winners[g]
        winner = teams[winner_id]
        println("  $(winner.region)$(winner.seed)")
    end
    
    # Championship Teams
    g_semis = [61, 62]
    println("\nChampionship Matchup:")
    team1_id = bracket.winners[g_semis[1]]
    team2_id = bracket.winners[g_semis[2]]
    team1 = teams[team1_id]
    team2 = teams[team2_id]
    winner_id = bracket.winners[63]
    winner = teams[winner_id]
    
    println("  $(team1.region)$(team1.seed) vs $(team2.region)$(team2.seed) → $(winner.region)$(winner.seed) CHAMPION")
end

"""
    run_tournament_optimization(;
        apply_upset_constraints=false, 
        final_four_teams=nothing,
        championship_winner=nothing,
        championship_runner_up=nothing)

Run the full tournament optimization with optional constraints.
Parameters:
- apply_upset_constraints: If true, enforce minimum upsets per round
- final_four_teams: Dictionary mapping region to seed for Final Four teams
- championship_winner: Tuple (region, seed) for the championship winner
- championship_runner_up: Tuple (region, seed) for the championship runner-up

Returns a tuple of (bracket, teams, games).
"""
function run_tournament_optimization(;
        apply_upset_constraints=false, 
        final_four_teams=nothing,
        championship_winner=nothing,
        championship_runner_up=nothing)
        
    # Initialize teams and tournament structure
    teams = initialize_teams()
    games = initialize_tournament_structure(teams)
    advancement_probs = create_realistic_advancement_probs(teams)
    
    # Print advancement probabilities by seed
    println("Advancement Probabilities By Seed for Round 1:")
    for seed in 1:16
        team_ids = [id for (id, team) in teams if team.seed == seed]
        avg_prob = mean([advancement_probs[(id, 1)] for id in team_ids])
        println("  Seed $seed: $(round(avg_prob, digits=3))")
    end
    
    # Print any special constraints being applied
    if final_four_teams !== nothing
        println("\nApplying Final Four Constraints:")
        for (region, seed) in final_four_teams
            println("  $region region: seed $seed")
        end
    end
    
    if championship_winner !== nothing && championship_runner_up !== nothing
        println("\nApplying Championship Game Constraint:")
        winner_region, winner_seed = championship_winner
        loser_region, loser_seed = championship_runner_up
        println("  Winner: $(winner_region)$(winner_seed)")
        println("  Runner-up: $(loser_region)$(loser_seed)")
    end
    
    # Optimize the bracket
    bracket = optimize_bracket(
        teams, 
        games, 
        advancement_probs; 
        apply_upset_constraints=apply_upset_constraints,
        final_four_teams=final_four_teams,
        championship_winner=championship_winner,
        championship_runner_up=championship_runner_up
    )
    
    # Print and analyze the results
    print_bracket(bracket, teams, games)
    analyze_bracket(bracket, teams, games)
    
    return bracket, teams, games
end

"""
    run_with_custom_final_four(final_four_teams, championship_matchup=nothing)

Run tournament optimization with specific Final Four teams.
Parameters:
- final_four_teams: Dictionary mapping region to seed
- championship_matchup: Optional tuple ((winner_region, winner_seed), (loser_region, loser_seed))
- semifinal_structure: Dictionary mapping region to game ID for semifinals
- apply_upset_constraints: If true, enforce minimum upsets per round
- upset_prop: Percentage of upsets to enforce in each round

Returns the optimized bracket.
"""
function run_with_custom_final_four(; final_four_teams, 
        championship_matchup=nothing, 
        semifinal_structure=Dict("E" => 61, "MW" => 61, "W" => 62, "S" => 62),
        apply_upset_constraints=false,
        upset_prop=0.5)
    # Initialize teams and tournament structure
    teams = initialize_teams()
    games = initialize_tournament_structure(teams)
    advancement_probs = create_realistic_advancement_probs(teams)

    # Define Elite 8 games mapping
    elite_8_games = Dict(
    "E" => 57,
    "W" => 58,
    "MW" => 59,
    "S" => 60
    )

    # Modify the tournament structure to match our desired semifinal pairings
    println("Modifying tournament structure for custom Final Four matchups:")
    for (region, semifinal) in semifinal_structure
        elite_8_game = elite_8_games[region]
        original_game = games[elite_8_game]

        # Update the next_game field to point to our desired semifinal
        games[elite_8_game] = Game(
            original_game.id,
            original_game.round,
            original_game.region,
            original_game.team1_id,
            original_game.team2_id,
            semifinal  # Change this to our desired semifinal
        )
        println("  Region $region (Elite 8 game $elite_8_game) now advances to semifinal $semifinal")
    end

    # Verify the tournament structure
    println("\nVerified tournament structure:")
    for g in 57:60
        println("  Game $g: next_game = $(games[g].next_game), region = $(games[g].region)")
    end

    
    # Create optimization model
    model = Model(GLPK.Optimizer)
    set_optimizer_attribute(model, "msg_lev", GLPK.GLP_MSG_ALL)  # Reduce output
    
    # Decision variables: w[g,t] = 1 if team t wins game g
    @variable(model, w[1:TOTAL_GAMES, 1:NUM_TEAMS], Bin)
    
    # Helper variable: is_upset[g] = 1 if game g results in an upset
    @variable(model, is_upset[1:TOTAL_GAMES], Bin)
    
    # Helper variable: tracking which teams play in each game
    @variable(model, plays_in[1:TOTAL_GAMES, 1:NUM_TEAMS], Bin)
    
    # First round constraints - predetermined matchups
    for g in 1:GAMES_PER_ROUND[1]
        game = games[g]
        team1_id, team2_id = game.team1_id, game.team2_id
        
        # Only team1 or team2 can win game g
        @constraint(model, w[g, team1_id] + w[g, team2_id] == 1)
        
        # No other team can win this game
        for t in 1:NUM_TEAMS
            if t != team1_id && t != team2_id
                @constraint(model, w[g, t] == 0)
            end
        end
        
        # Mark these teams as playing in this game
        @constraint(model, plays_in[g, team1_id] == 1)
        @constraint(model, plays_in[g, team2_id] == 1)
        
        # Define upsets for round 1
        team1_seed = teams[team1_id].seed
        team2_seed = teams[team2_id].seed
        
        if team1_seed < team2_seed  # team1 is better seeded (lower number)
            @constraint(model, is_upset[g] == w[g, team2_id])
        elseif team1_seed > team2_seed  # team2 is better seeded
            @constraint(model, is_upset[g] == w[g, team1_id])
        else  # Equal seeds can't be an upset
            @constraint(model, is_upset[g] == 0)
        end
    end
    
    # Constraints for later rounds
    for r in 2:NUM_ROUNDS
        start_game = sum(GAMES_PER_ROUND[1:(r-1)]) + 1
        end_game = sum(GAMES_PER_ROUND[1:r])
        
        for g in start_game:end_game
            game = games[g]
            
            # Determine which games feed into this one
            prev_games = []
            for prev_g in 1:(start_game-1)
                if games[prev_g].next_game == g
                    push!(prev_games, prev_g)
                end
            end
            
            # A team can only win this game if it won one of the previous games
            for t in 1:NUM_TEAMS
                @constraint(model, w[g, t] <= sum(w[prev_g, t] for prev_g in prev_games))
                
                # A team plays in this game if it won one of the previous games
                @constraint(model, plays_in[g, t] == sum(w[prev_g, t] for prev_g in prev_games))
            end
            
            # Exactly one team wins this game
            @constraint(model, sum(w[g, t] for t in 1:NUM_TEAMS) == 1)
            
            # For tracking upsets in later rounds, we need additional variables
            # to ensure that is_upset[g] is properly connected to actual upsets
            
            # Store all potential upset conditions for this game
            upset_conditions = []
            
            # Create a binary variable for each potential matchup in this game
            for t1 in 1:NUM_TEAMS
                for t2 in (t1+1):NUM_TEAMS
                    # Skip if teams are from the same region in Final Four (they can't meet)
                    if r >= 5 && teams[t1].region == teams[t2].region
                        continue
                    end
                    
                    # matchup[t1,t2] = 1 if t1 and t2 play against each other in game g
                    matchup = @variable(model, binary=true)
                    
                    # Set matchup = 1 if both teams play in this game
                    @constraint(model, matchup <= plays_in[g, t1])
                    @constraint(model, matchup <= plays_in[g, t2])
                    @constraint(model, matchup >= plays_in[g, t1] + plays_in[g, t2] - 1)
                    
                    # Create upset condition variables for both possible outcomes
                    team1_seed = teams[t1].seed
                    team2_seed = teams[t2].seed
                    
                    if team1_seed < team2_seed  # t1 is better seeded
                        # If t2 wins, it's an upset
                        upset_var = @variable(model, binary=true)
                        
                        # upset_var is 1 if and only if this matchup occurs AND t2 wins
                        @constraint(model, upset_var <= matchup)
                        @constraint(model, upset_var <= w[g, t2])
                        @constraint(model, upset_var >= matchup + w[g, t2] - 1)
                        
                        # Add this to our list of potential upset conditions
                        push!(upset_conditions, upset_var)
                    elseif team1_seed > team2_seed  # t2 is better seeded
                        # If t1 wins, it's an upset
                        upset_var = @variable(model, binary=true)
                        
                        # upset_var is 1 if and only if this matchup occurs AND t1 wins
                        @constraint(model, upset_var <= matchup)
                        @constraint(model, upset_var <= w[g, t1])
                        @constraint(model, upset_var >= matchup + w[g, t1] - 1)
                        
                        # Add this to our list of potential upset conditions
                        push!(upset_conditions, upset_var)
                    end
                end
            end
            
            # is_upset[g] is 1 if and only if any of the upset conditions are true
            if !isempty(upset_conditions)
                # is_upset[g] is at least 1 if any upset condition is true
                @constraint(model, is_upset[g] <= sum(upset_conditions))
                
                # For each individual upset condition, if it's true, is_upset[g] must be 1
                for uc in upset_conditions
                    @constraint(model, is_upset[g] >= uc)
                end
            else
                # If no upset conditions exist for this game, is_upset[g] must be 0
                @constraint(model, is_upset[g] == 0)
            end
        end
    end
    
    # Instead of tracing full paths, create a reduced set of constraints:
    
    # 1. Find the Elite 8 games for each region
    elite_8_games = Dict(
        "E" => 57,
        "W" => 58,
        "MW" => 59,
        "S" => 60
    )
    
    # 2. Find Final Four semifinal structure
    semifinal_games = semifinal_structure
    
    # 3. Set up constraints for Final Four teams
    println("Adding Final Four team constraints:")
    for (region, seed) in final_four_teams
        # Find the team ID
        team_id = 0
        for (id, team) in teams
            if team.region == region && team.seed == seed
                team_id = id
                break
            end
        end
        
        if team_id == 0
            error("Could not find team with region $region and seed $seed")
        end
        
        # Constrain this team to win its Elite 8 game
        elite_8_game = elite_8_games[region]
        println("  $(region)$(seed) wins Elite 8 game $elite_8_game")
        @constraint(model, w[elite_8_game, team_id] == 1)
    end
    
    # 4. Optional championship constraints
    if championship_matchup !== nothing
        winner_info, loser_info = championship_matchup
        winner_region, winner_seed = winner_info
        loser_region, loser_seed = loser_info
        
        # Find team IDs
        winner_id = 0
        loser_id = 0
        
        for (id, team) in teams
            if team.region == winner_region && team.seed == winner_seed
                winner_id = id
            elseif team.region == loser_region && team.seed == loser_seed
                loser_id = id
            end
        end
        
        if winner_id == 0 || loser_id == 0
            error("Could not find championship teams")
        end
        
        # Check compatibility of regions
        if semifinal_games[winner_region] == semifinal_games[loser_region]
            error("Championship teams cannot both come from regions that play in the same semifinal")
        end
        
        # Add semifinal constraints - this needs to match your modified structure
        winner_semifinal = semifinal_games[winner_region]
        loser_semifinal = semifinal_games[loser_region]
        
        # Debug output to see what's happening
        println("Debug - Winner semifinal mapping:")
        println("  $(winner_region) maps to game $(winner_semifinal)")
        println("Debug - Loser semifinal mapping:")
        println("  $(loser_region) maps to game $(loser_semifinal)")
        
        # Add constraints
        println("  $(winner_region)$(winner_seed) wins semifinal $winner_semifinal")
        @constraint(model, w[winner_semifinal, winner_id] == 1)
        
        println("  $(loser_region)$(loser_seed) wins semifinal $loser_semifinal")
        @constraint(model, w[loser_semifinal, loser_id] == 1)
        
        # Add championship constraint
        println("  $(winner_region)$(winner_seed) wins championship (game 63)")
        @constraint(model, w[63, winner_id] == 1)
    end
    
    println("\nVerifying constraint consistency...")
    for (g, _) in games
        if g >= 57  # Elite 8 and beyond
            println("  Game $g: next_game = $(games[g].next_game), region = $(games[g].region)")
        end
    end
    
    # Apply upset constraints if requested
    if apply_upset_constraints
        # Modified to add more realistic upset distributions:
        # Higher upset percentages in early rounds, lower in later rounds
        upset_percentages = upset_prop*ones(NUM_ROUNDS)
        
        for r in 1:NUM_ROUNDS
            start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
            end_game = sum(GAMES_PER_ROUND[1:r])
            
            # At least the specified percentage of games in this round must be upsets
            min_upsets = ceil(Int, GAMES_PER_ROUND[r] * upset_percentages[r])
            @constraint(model, sum(is_upset[g] for g in start_game:end_game) >= min_upsets)
        end
    end
    
    # Objective: Maximize expected score using simplified scoring
    @objective(model, Max, sum(w[g, t] * advancement_probs[(t, games[g].round)] for g in 1:TOTAL_GAMES, t in 1:NUM_TEAMS))
    
    # Solve the model
    println("Solving model...")
    optimize!(model)
    
    # Check if a solution was found
    if termination_status(model) != MOI.OPTIMAL
        println("Status: ", termination_status(model))
        println("Reason: ", raw_status(model))
        error("No optimal solution found")
    end
    
    # Extract the results
    winners = Dict{Int, Int}()
    for g in 1:TOTAL_GAMES
        for t in 1:NUM_TEAMS
            if value(w[g, t]) > 0.5
                winners[g] = t
                break
            end
        end
    end
    
    # Return a simplified bracket
    return Bracket(winners, 0.0, Dict{Int, Int}())
end

"""
    print_full_bracket(bracket, teams, games)

Print the complete bracket with all picks from first round to championship.
"""
function print_full_bracket(bracket, teams, games)
    println("\n===== COMPLETE BRACKET =====\n")
    
    # Print each round
    round_names = ["First Round", "Second Round", "Sweet 16", "Elite 8", "Final Four", "Championship"]
    
    for r in 1:NUM_ROUNDS
        println(round_names[r] * ":")
        
        start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
        end_game = sum(GAMES_PER_ROUND[1:r])
        
        for g in start_game:end_game
            game = games[g]
            
            if !haskey(bracket.winners, g)
                println("  Game $g: No winner determined")
                continue
            end
            
            winner_id = bracket.winners[g]
            winner = teams[winner_id]
            
            # Determine the teams that played in this game
            if r == 1
                # First round has predetermined matchups
                team1_id, team2_id = game.team1_id, game.team2_id
                team1, team2 = teams[team1_id], teams[team2_id]
                
                println("  Game $g: $(team1.region)$(team1.seed) vs $(team2.region)$(team2.seed) → $(winner.region)$(winner.seed) advances")
            else
                # Later rounds need to look at previous winners
                prev_games = []
                for prev_g in 1:(g-1)
                    if games[prev_g].next_game == g
                        push!(prev_games, prev_g)
                    end
                end
                
                if length(prev_games) != 2
                    println("  Game $g: Unable to determine matchup (expected 2 previous games, found $(length(prev_games)))")
                    continue
                end
                
                prev_game1, prev_game2 = prev_games
                
                if !haskey(bracket.winners, prev_game1) || !haskey(bracket.winners, prev_game2)
                    println("  Game $g: Missing previous game winners")
                    continue
                end
                
                team1_id, team2_id = bracket.winners[prev_game1], bracket.winners[prev_game2]
                team1, team2 = teams[team1_id], teams[team2_id]
                
                if r == NUM_ROUNDS
                    println("  Game $g: $(team1.region)$(team1.seed) vs $(team2.region)$(team2.seed) → $(winner.region)$(winner.seed) CHAMPION")
                else
                    println("  Game $g: $(team1.region)$(team1.seed) vs $(team2.region)$(team2.seed) → $(winner.region)$(winner.seed) advances")
                end
            end
        end
        println()
    end
end

"""
    print_bracket_with_upsets(bracket, teams, games, upset_pct=0.5)

Print the complete bracket with all picks from first round to championship,
highlighting upsets and providing upset statistics based on the custom upset percentage.
"""
function print_bracket_with_upsets(bracket, teams, games, upset_pct=0.5)
    println("\n===== COMPLETE BRACKET WITH UPSET ANALYSIS =====\n")
    println("Upset Threshold: $(upset_pct * 100)% per round")
    
    # Print each round
    round_names = ["First Round", "Second Round", "Sweet 16", "Elite 8", "Final Four", "Championship"]
    
    # Track upsets by round
    upsets_by_round = Dict{Int, Int}()
    for r in 1:NUM_ROUNDS
        upsets_by_round[r] = 0
    end
    
    # Calculate upset threshold for each round (with decreasing percentages in later rounds)
    upset_thresholds = Dict{Int, Int}()
    upset_percentages = Dict{Int, Float64}()
    for r in 1:NUM_ROUNDS
        # Scale upset percentage by round (lower expectations in later rounds)
        round_factor = 1.0
        #if r == 2
        #    round_factor = 0.9
        #elseif r == 3
        #    round_factor = 0.8
        #elseif r == 4
        #    round_factor = 0.7
        #elseif r == 5
        #    round_factor = 0.6
        #elseif r == 6
        #    round_factor = 0.5
        #end
        
        adjusted_pct = upset_pct * round_factor
        upset_percentages[r] = adjusted_pct
        upset_thresholds[r] = ceil(Int, GAMES_PER_ROUND[r] * adjusted_pct)
    end
    
    for r in 1:NUM_ROUNDS
        println("\n" * round_names[r] * ":")
        
        start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
        end_game = sum(GAMES_PER_ROUND[1:r])
        
        for g in start_game:end_game
            game = games[g]
            
            if !haskey(bracket.winners, g)
                println("  Game $g: No winner determined")
                continue
            end
            
            winner_id = bracket.winners[g]
            winner = teams[winner_id]
            
            # Determine the teams that played in this game
            if r == 1
                # First round has predetermined matchups
                team1_id, team2_id = game.team1_id, game.team2_id
                team1, team2 = teams[team1_id], teams[team2_id]
                
                # Check if this is an upset
                is_upset = (team1.seed < team2.seed && winner_id == team2_id) || 
                           (team1.seed > team2.seed && winner_id == team1_id)
                
                if is_upset
                    upsets_by_round[r] += 1
                    upset_str = " [UPSET!]"
                else
                    upset_str = ""
                end
                
                println("  Game $g: $(team1.region)$(team1.seed) vs $(team2.region)$(team2.seed) → $(winner.region)$(winner.seed) advances$upset_str")
            else
                # Later rounds need to look at previous winners
                prev_games = []
                for prev_g in 1:(g-1)
                    if games[prev_g].next_game == g
                        push!(prev_games, prev_g)
                    end
                end
                
                if length(prev_games) != 2
                    println("  Game $g: Unable to determine matchup (expected 2 previous games, found $(length(prev_games)))")
                    continue
                end
                
                prev_game1, prev_game2 = prev_games
                
                if !haskey(bracket.winners, prev_game1) || !haskey(bracket.winners, prev_game2)
                    println("  Game $g: Missing previous game winners")
                    continue
                end
                
                team1_id, team2_id = bracket.winners[prev_game1], bracket.winners[prev_game2]
                team1, team2 = teams[team1_id], teams[team2_id]
                
                # Check if this is an upset
                is_upset = (team1.seed < team2.seed && winner_id == team2_id) || 
                           (team1.seed > team2.seed && winner_id == team1_id)
                
                if is_upset
                    upsets_by_round[r] += 1
                    upset_str = " [UPSET!]"
                else
                    upset_str = ""
                end
                
                if r == NUM_ROUNDS
                    println("  Game $g: $(team1.region)$(team1.seed) vs $(team2.region)$(team2.seed) → $(winner.region)$(winner.seed) CHAMPION$upset_str")
                else
                    println("  Game $g: $(team1.region)$(team1.seed) vs $(team2.region)$(team2.seed) → $(winner.region)$(winner.seed) advances$upset_str")
                end
            end
        end
        
        # Print upset statistics for this round
        games_in_round = GAMES_PER_ROUND[r]
        upsets = upsets_by_round[r]
        pct = upsets / games_in_round * 100
        threshold = upset_thresholds[r]
        threshold_pct = upset_percentages[r] * 100
        
        if upsets >= threshold
            meeting_str = "✓ Meeting target"
        else
            meeting_str = "✗ Below target"
        end
        
        println("\nUpsets in $(round_names[r]): $upsets/$games_in_round ($(round(pct, digits=1))%)")
        println("Target: $threshold ($(round(threshold_pct, digits=1))%) - $meeting_str")
    end
    
    # Print overall statistics
    total_upsets = sum(values(upsets_by_round))
    total_games = TOTAL_GAMES
    total_pct = total_upsets / total_games * 100
    
    total_threshold = sum(values(upset_thresholds))
    avg_threshold_pct = total_threshold / total_games * 100
    
    println("\n===== UPSET SUMMARY =====")
    println("Total Upsets: $total_upsets/$total_games ($(round(total_pct, digits=1))%)")
    println("Overall Target: $total_threshold/$total_games ($(round(avg_threshold_pct, digits=1))%)")
    
    if total_upsets >= total_threshold
        println("✓ Overall upset target achieved")
    else
        println("✗ Overall upset target not met")
    end
    
    # Print the Final Four and Championship
    println("\n===== FINAL RESULTS =====")
    
    # Get Final Four teams - these are the winners of the Elite 8 games
    final_four_teams = Dict{String, Tuple{Int, String}}()
    for (i, region) in enumerate(REGIONS)
        elite_8_game = 56 + i  # Games 57, 58, 59, 60
        if haskey(bracket.winners, elite_8_game)
            winner_id = bracket.winners[elite_8_game]
            winner_seed = teams[winner_id].seed
            winner_region = teams[winner_id].region
            final_four_teams[region] = (winner_id, "$(winner_region)$(winner_seed)")
        end
    end
    
    # Print Final Four teams
    println("Final Four Teams:")
    for region in REGIONS
        if haskey(final_four_teams, region)
            _, team_str = final_four_teams[region]
            println("  $region Region Champion: $team_str")
        else
            println("  $region Region Champion: Unknown")
        end
    end
    
    # Print Semifinal Games
    println("\nSemifinal Games:")
    
    # First semifinal (game 61) - traditionally E vs W
    if haskey(bracket.winners, 61)
        # Find which regions feed into semifinal 1
        regions_in_semi1 = []
        for (region, _) in final_four_teams
            if haskey(games, 56 + findfirst(r -> r == region, REGIONS))
                game = games[56 + findfirst(r -> r == region, REGIONS)]
                if game.next_game == 61
                    push!(regions_in_semi1, region)
                end
            end
        end
        
        if length(regions_in_semi1) == 2
            region1, region2 = regions_in_semi1
            _, team1_str = final_four_teams[region1]
            _, team2_str = final_four_teams[region2]
            winner_id = bracket.winners[61]
            winner = teams[winner_id]
            println("  Game 61: $team1_str vs $team2_str → $(winner.region)$(winner.seed) advances")
        else
            println("  Game 61: Unable to determine matchup")
        end
    else
        println("  Game 61: No winner determined")
    end
    
    # Second semifinal (game 62) - traditionally MW vs S
    if haskey(bracket.winners, 62)
        # Find which regions feed into semifinal 2
        regions_in_semi2 = []
        for (region, _) in final_four_teams
            if haskey(games, 56 + findfirst(r -> r == region, REGIONS))
                game = games[56 + findfirst(r -> r == region, REGIONS)]
                if game.next_game == 62
                    push!(regions_in_semi2, region)
                end
            end
        end
        
        if length(regions_in_semi2) == 2
            region1, region2 = regions_in_semi2
            _, team1_str = final_four_teams[region1]
            _, team2_str = final_four_teams[region2]
            winner_id = bracket.winners[62]
            winner = teams[winner_id]
            println("  Game 62: $team1_str vs $team2_str → $(winner.region)$(winner.seed) advances")
        else
            println("  Game 62: Unable to determine matchup")
        end
    else
        println("  Game 62: No winner determined")
    end
    
    # Championship Game
    println("\nChampionship Game:")
    if haskey(bracket.winners, 61) && haskey(bracket.winners, 62) && haskey(bracket.winners, 63)
        team1_id = bracket.winners[61]
        team2_id = bracket.winners[62]
        champion_id = bracket.winners[63]
        
        team1 = teams[team1_id]
        team2 = teams[team2_id]
        champion = teams[champion_id]
        
        println("  Game 63: $(team1.region)$(team1.seed) vs $(team2.region)$(team2.seed) → $(champion.region)$(champion.seed) CHAMPION")
    else
        println("  Game 63: Unknown matchup")
    end
end

end # End of module