module MarchMadnessOptimizer
using Statistics, JuMP, HiGHS, DelimitedFiles

export initialize_teams, create_first_round_matchups, initialize_tournament_structure,
       create_realistic_advancement_probs, load_teams_and_probs,
       resolve_team_id, optimize_bracket, calculate_bracket_score,
       print_bracket, analyze_bracket, run_tournament_optimization,
       run_with_custom_final_four

# Constants for tournament structure
const NUM_TEAMS = 64
const NUM_ROUNDS = 6
const GAMES_PER_ROUND = [32, 16, 8, 4, 2, 1]
const TOTAL_GAMES = sum(GAMES_PER_ROUND)
const REGIONS = ["E", "W", "MW", "S"]
const TEAMS_PER_REGION = NUM_TEAMS ÷ 4
# Max "expected" seed to reach each round; anything higher is a Cinderella
const CINDERELLA_THRESHOLDS = [8, 4, 2, 1, 1, 1]

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
    winners::Dict{Int, Int}       # Map from game ID to winning team ID
    score::Float64                # Expected score of this bracket
    upsets::Dict{Int, Int}        # Number of upsets per round
    cinderellas::Dict{Int, Int}   # Number of cinderellas per round (empty if not cinderella_mode)
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
    resolve_team_id(teams, identifier::String)

Resolve a team identifier (name like "BYU" or region+seed like "E6") to a team ID.
"""
function resolve_team_id(teams, identifier::String)
    # Try exact name match (case-insensitive)
    id_lower = lowercase(identifier)
    for (id, team) in teams
        if lowercase(team.name) == id_lower
            return id
        end
    end
    # Try region+seed format (e.g. "E6", "MW11")
    m = match(r"^(E|W|MW|S)(\d+)$"i, identifier)
    if m !== nothing
        region = uppercase(String(m[1]))
        seed = parse(Int, m[2])
        for (id, team) in teams
            if team.region == region && team.seed == seed
                return id
            end
        end
    end
    # Collect available names for error message
    names = sort([team.name for (_, team) in teams if team.name != ""])
    error("Could not resolve team '$identifier'. Available: $(join(names[1:min(10,length(names))], ", "))...")
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
    load_teams_and_probs(filepath)

Load teams and advancement probabilities from a data file.
Supports two formats:
- 538-style whitespace-delimited (`.txt`):
      1E  Duke              99.5   84.6   69.4   52.5   35.6   22.9
- KenPom-style CSV (`.csv`):
      1E,Duke,99.1,85.3,69.0,52.7,33.3,21.0

Returns (teams, advancement_probs) in the same Dict formats as
initialize_teams() and create_realistic_advancement_probs().
"""
function load_teams_and_probs(filepath)
    lines = readlines(filepath)

    # Auto-detect format: CSV if first non-blank line contains commas
    is_csv = false
    for line in lines
        stripped = strip(line)
        isempty(stripped) && continue
        if occursin(",", stripped)
            is_csv = true
        end
        break
    end

    # Skip header line(s) and blank lines
    data_lines = String[]
    for line in lines
        stripped = strip(line)
        isempty(stripped) && continue
        # Skip header: contains "Rd2" or "Swt16" or "Sweet16" or "Seed_Region"
        if occursin("Rd2", stripped) || occursin("Swt16", stripped) ||
           occursin("Sweet16", stripped) || occursin("Seed_Region", stripped)
            continue
        end
        push!(data_lines, line)
    end

    # Parse each line into (seed, region, name, probs[1:6])
    parsed = []

    # Parse probability values, handling "<.001"
    function parse_prob(s)
        s = strip(s)
        if startswith(s, "<")
            return 0.0
        else
            return parse(Float64, s) / 100.0
        end
    end

    for line in data_lines
        if is_csv
            # CSV format: "1E,Duke,99.1,85.3,69.0,52.7,33.3,21.0"
            fields = split(line, ",")
            if length(fields) < 8
                @warn "Could not parse CSV line: $line"
                continue
            end
            m = match(r"^(\d+)(E|W|MW|S)$", strip(fields[1]))
            if m === nothing
                @warn "Could not parse seed/region from: $(fields[1])"
                continue
            end
            seed = parse(Int, m[1])
            region = String(m[2])
            name = strip(String(fields[2]))
            probs = [parse_prob(fields[i]) for i in 3:8]
        else
            # 538-style whitespace-delimited format
            m = match(r"^\s*(\d+)(E|W|MW|S)\s+(.+?)\s+([\d.<]+)\s+([\d.<]+)\s+([\d.<]+)\s+([\d.<]+)\s+([\d.<]+)\s+([\d.<]+)\s*$", line)
            if m === nothing
                @warn "Could not parse line: $line"
                continue
            end
            seed = parse(Int, m[1])
            region = String(m[2])
            name = strip(String(m[3]))
            probs = [parse_prob(m[i]) for i in 4:9]
        end
        push!(parsed, (seed=seed, region=region, name=name, probs=probs))
    end

    # Handle play-in games: when two teams share the same region+seed,
    # keep the one with the higher R32 (round 1) probability
    key_groups = Dict{Tuple{Int,String}, Vector{eltype(parsed)}}()
    for entry in parsed
        key = (entry.seed, entry.region)
        if !haskey(key_groups, key)
            key_groups[key] = [entry]
        else
            push!(key_groups[key], entry)
        end
    end

    deduped = []
    for (key, group) in key_groups
        if length(group) == 1
            push!(deduped, group[1])
        else
            # Keep the team with higher R32 (round 1) probability
            best = argmax(e -> e.probs[1], group)
            push!(deduped, best)
            dropped_names = [e.name for e in group if e !== best]
            println("Play-in: keeping $(best.name) over $(join(dropped_names, ", ")) for seed $(key[1])$(key[2])")
        end
    end

    # Verify we have exactly 64 teams
    if length(deduped) != 64
        error("Expected 64 teams after deduplication, got $(length(deduped))")
    end

    # Assign team IDs using the same convention as initialize_teams():
    # regions ["E","W","MW","S"], seeds 1-16, sequential IDs
    teams = Dict{Int, Team}()
    team_id = 1
    for region in REGIONS
        for seed in 1:16
            # Find the parsed entry for this region+seed
            entry = nothing
            for e in deduped
                if e.region == region && e.seed == seed
                    entry = e
                    break
                end
            end
            if entry === nothing
                error("No team found for region $region seed $seed")
            end
            teams[team_id] = Team(team_id, region, seed, entry.name)
            team_id += 1
        end
    end

    # Build advancement_probs dict: (team_id, round) -> probability
    # Column mapping: Rd2→round1, Swt16→round2, Elite8→round3, Final4→round4, Final→round5, Champ→round6
    advancement_probs = Dict{Tuple{Int, Int}, Float64}()
    for (id, team) in teams
        # Find the parsed entry matching this team
        entry = nothing
        for e in deduped
            if e.region == team.region && e.seed == team.seed
                entry = e
                break
            end
        end
        for r in 1:NUM_ROUNDS
            advancement_probs[(id, r)] = entry.probs[r]
        end
    end

    return teams, advancement_probs
end

"""
    optimize_bracket(teams, games, advancement_probs; kwargs...)

Optimize the bracket to maximize expected score.

Keyword arguments:
- `apply_upset_constraints`: If true, enforce minimum upsets/cinderellas (default false)
- `upset_prop`: Fraction of games that must be upsets/cinderellas (default 0.5)
- `upset_mode`: `:per_round` (default) or `:per_region` (e.g. 1/3 upsets per region)
- `cinderella_mode`: If true, count cinderellas instead of upsets (default false)
- `forced_advancements`: Dict mapping team name/code to round they must reach
  (e.g. `Dict("BYU" => 3)` forces BYU to the Sweet 16)
- `final_four_teams`: Dict mapping region to seed for Final Four teams
- `championship_winner`: Tuple (region, seed) for the championship winner
- `championship_runner_up`: Tuple (region, seed) for the championship runner-up
"""
function optimize_bracket(teams, games, advancement_probs;
                         apply_upset_constraints=false,
                         upset_prop=0.5,
                         upset_mode=:per_round,
                         cinderella_mode=false,
                         forced_advancements=nothing,
                         max_advancements=nothing,
                         final_four_teams=nothing,
                         championship_winner=nothing,
                         championship_runner_up=nothing)
    # Create optimization model
    model = Model(HiGHS.Optimizer)
    
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
    
    # Seed-difference variable for upset detection in rounds 2-6
    # D[g] = seed(winner) - seed(loser); D[g] > 0 means upset
    @variable(model, -15 <= D[1:TOTAL_GAMES] <= 15)

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

            # Seed-difference upset detection:
            # D[g] = sum_t seed(t) * (2*w[g,t] - plays_in[g,t])
            #       = seed(winner) - seed(loser)
            # If D[g] > 0, the higher-seeded (worse) team won → upset
            @constraint(model, D[g] == sum(teams[t].seed * (2*w[g,t] - plays_in[g,t]) for t in 1:NUM_TEAMS))

            # Link D[g] to is_upset[g] via big-M (M=15, max seed difference)
            @constraint(model, D[g] <= 15 * is_upset[g])          # D<=0 → is_upset can be 0
            @constraint(model, D[g] >= 16 * is_upset[g] - 15)     # D>=1 → is_upset must be 1
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
    if championship_winner !== nothing
        winner_region, winner_seed = championship_winner

        # Find team ID for winner
        winner_id = 0
        for (id, team) in teams
            if team.region == winner_region && team.seed == winner_seed
                winner_id = id
                break
            end
        end
        if winner_id == 0
            error("Could not find championship winner team with region $winner_region and seed $winner_seed")
        end

        e_mw_semifinal = 61  # First semifinal: E vs MW
        w_s_semifinal = 62   # Second semifinal: W vs S

        # Winner team wins the championship (game 63) and their semifinal
        @constraint(model, w[63, winner_id] == 1)
        if winner_region == "E" || winner_region == "MW"
            @constraint(model, w[e_mw_semifinal, winner_id] == 1)
        else
            @constraint(model, w[w_s_semifinal, winner_id] == 1)
        end

        # Optionally force the runner-up to reach the championship too
        if championship_runner_up !== nothing
            loser_region, loser_seed = championship_runner_up
            loser_id = 0
            for (id, team) in teams
                if team.region == loser_region && team.seed == loser_seed
                    loser_id = id
                    break
                end
            end
            if loser_id == 0
                error("Could not find championship runner-up team with region $loser_region and seed $loser_seed")
            end
            if loser_region == "E" || loser_region == "MW"
                @constraint(model, w[e_mw_semifinal, loser_id] == 1)
            else
                @constraint(model, w[w_s_semifinal, loser_id] == 1)
            end
        end
    end
    
    # Forced advancement constraints (e.g. "BYU must make the Sweet 16")
    if forced_advancements !== nothing
        for (team_identifier, target_round) in forced_advancements
            team_id = resolve_team_id(teams, team_identifier)
            team = teams[team_id]
            println("  Forcing $(team.name) ($(team.region)$(team.seed)) to reach round $target_round")
            if target_round >= 2
                # Constrain team to win a game in round (target_round - 1).
                # Advancement constraints cascade backwards automatically.
                r = target_round - 1
                start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
                end_game = sum(GAMES_PER_ROUND[1:r])
                @constraint(model, sum(w[g, team_id] for g in start_game:end_game) >= 1)
            end
        end
    end

    # Max advancement constraints (team cannot win any game beyond a given round)
    # e.g. max_advancements = Dict("BYU" => 1) means BYU can win at most their round-1 game
    if max_advancements !== nothing
        for (team_identifier, max_round) in max_advancements
            team_id = resolve_team_id(teams, team_identifier)
            team = teams[team_id]
            println("  Capping $(team.name) ($(team.region)$(team.seed)) at max round $max_round (loses in round $(max_round) or $(max_round+1))")
            for r in (max_round+1):NUM_ROUNDS
                start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
                end_game = sum(GAMES_PER_ROUND[1:r])
                @constraint(model, sum(w[g, team_id] for g in start_game:end_game) == 0)
            end
        end
    end

    # Cinderella variables: is_cinderella[g] = 1 if winner's seed > threshold for that round
    if cinderella_mode
        @variable(model, 1 <= winner_seed[1:TOTAL_GAMES] <= 16)
        @variable(model, is_cinderella[1:TOTAL_GAMES], Bin)

        for g in 1:TOTAL_GAMES
            @constraint(model, winner_seed[g] == sum(teams[t].seed * w[g, t] for t in 1:NUM_TEAMS))
        end

        for r in 1:NUM_ROUNDS
            threshold = CINDERELLA_THRESHOLDS[r]
            start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
            end_game = sum(GAMES_PER_ROUND[1:r])
            for g in start_game:end_game
                @constraint(model, winner_seed[g] >= threshold + 1 - 16 * (1 - is_cinderella[g]))
                @constraint(model, winner_seed[g] <= threshold + 16 * is_cinderella[g])
            end
        end
    end

    # Apply quota constraints (upsets or cinderellas)
    if apply_upset_constraints
        quota_var = cinderella_mode ? is_cinderella : is_upset
        label = cinderella_mode ? "cinderella" : "upset"

        if upset_mode == :per_round
            for r in 1:NUM_ROUNDS
                start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
                end_game = sum(GAMES_PER_ROUND[1:r])
                min_count = ceil(Int, GAMES_PER_ROUND[r] * upset_prop)
                @constraint(model, sum(quota_var[g] for g in start_game:end_game) >= min_count)
            end
        elseif upset_mode == :per_region
            for region in REGIONS
                region_games = [g for g in 1:60 if games[g].region == region]
                min_count = ceil(Int, length(region_games) * upset_prop)
                @constraint(model, sum(quota_var[g] for g in region_games) >= min_count)
            end
            ff_games = [g for g in 61:63 if g <= TOTAL_GAMES]
            min_ff = ceil(Int, length(ff_games) * upset_prop)
            @constraint(model, sum(quota_var[g] for g in ff_games) >= min_ff)
        else
            error("Unknown upset_mode: $upset_mode. Valid: :per_round, :per_region")
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
        cinderellas_by_round = Dict{Int, Int}()

        for r in 1:NUM_ROUNDS
            upsets_by_round[r] = 0
            cinderellas_by_round[r] = 0
            start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
            end_game = sum(GAMES_PER_ROUND[1:r])

            for g in start_game:end_game
                for t in 1:NUM_TEAMS
                    if value(w[g, t]) > 0.5
                        winners[g] = t
                        if value(is_upset[g]) > 0.5
                            upsets_by_round[r] += 1
                        end
                        if cinderella_mode && value(is_cinderella[g]) > 0.5
                            cinderellas_by_round[r] += 1
                        end
                        break
                    end
                end
            end
        end

        score = calculate_bracket_score(winners, teams, advancement_probs)
        return Bracket(winners, score, upsets_by_round, cinderellas_by_round)
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
function team_label(t::Team)
    has_name = t.name != "" && !startswith(t.name, "Team ")
    has_name ? "$(t.name) ($(t.region)$(t.seed))" : "$(t.region)$(t.seed)"
end

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
                println("  Game $g: $(team_label(team1)) vs $(team_label(team2)) → $(team_label(winner)) advances$upset_str")
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
                    println("  Game $g: $(team_label(team1)) vs $(team_label(team2)) → $(team_label(winner)) CHAMPION$upset_str")
                else
                    println("  Game $g: $(team_label(team1)) vs $(team_label(team2)) → $(team_label(winner)) advances$upset_str")
                end
            end
        end
        
        # Print upset statistics for this round
        upsets = bracket.upsets[r]
        games_in_round = GAMES_PER_ROUND[r]
        pct = upsets / games_in_round * 100
        println("\nUpsets in $(round_names[r]): $upsets/$games_in_round ($(round(pct, digits=1))%)")

        # Print cinderella statistics if available
        if haskey(bracket.cinderellas, r) && bracket.cinderellas[r] > 0
            cind = bracket.cinderellas[r]
            cpct = cind / games_in_round * 100
            threshold = CINDERELLA_THRESHOLDS[r]
            println("Cinderellas in $(round_names[r]): $cind/$games_in_round ($(round(cpct, digits=1))%) [seed > $threshold]")
        end
        println()
    end

    # Print overall statistics
    total_upsets = sum(values(bracket.upsets))
    total_games = TOTAL_GAMES
    pct = total_upsets / total_games * 100
    println("Total Upsets: $total_upsets/$total_games ($(round(pct, digits=1))%)")

    if !isempty(bracket.cinderellas) && sum(values(bracket.cinderellas)) > 0
        total_cind = sum(values(bracket.cinderellas))
        cpct = total_cind / total_games * 100
        println("Total Cinderellas: $total_cind/$total_games ($(round(cpct, digits=1))%)")
    end

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
        println("  $(team_label(winner))")
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

    println("  $(team_label(team1)) vs $(team_label(team2)) → $(team_label(winner)) CHAMPION")
end

"""
    run_tournament_optimization(; kwargs...)

Run the full tournament optimization with optional constraints.
Returns a tuple of (bracket, teams, games).

See `optimize_bracket` for all keyword arguments. Additional:
- `filepath`: Path to 538-style probability data file (uses generated data if nothing)
"""
function run_tournament_optimization(;
        filepath=nothing,
        apply_upset_constraints=false,
        upset_prop=0.5,
        upset_mode=:per_round,
        cinderella_mode=false,
        forced_advancements=nothing,
        max_advancements=nothing,
        final_four_teams=nothing,
        championship_winner=nothing,
        championship_runner_up=nothing)

    # Initialize teams and tournament structure
    if filepath !== nothing
        teams, advancement_probs = load_teams_and_probs(filepath)
    else
        teams = initialize_teams()
        advancement_probs = create_realistic_advancement_probs(teams)
    end
    games = initialize_tournament_structure(teams)
    
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
    
    if championship_winner !== nothing
        println("\nApplying Championship Game Constraint:")
        winner_region, winner_seed = championship_winner
        println("  Winner: $(winner_region)$(winner_seed)")
        if championship_runner_up !== nothing
            loser_region, loser_seed = championship_runner_up
            println("  Runner-up: $(loser_region)$(loser_seed)")
        end
    end
    
    # Optimize the bracket
    bracket = optimize_bracket(
        teams,
        games,
        advancement_probs;
        apply_upset_constraints=apply_upset_constraints,
        upset_prop=upset_prop,
        upset_mode=upset_mode,
        cinderella_mode=cinderella_mode,
        forced_advancements=forced_advancements,
        max_advancements=max_advancements,
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
        filepath=nothing,
        championship_matchup=nothing,
        semifinal_structure=Dict("E" => 61, "MW" => 61, "W" => 62, "S" => 62),
        apply_upset_constraints=false,
        upset_prop=0.5,
        upset_mode=:per_round,
        cinderella_mode=false,
        forced_advancements=nothing)
    # Initialize teams and tournament structure
    if filepath !== nothing
        teams, advancement_probs = load_teams_and_probs(filepath)
    else
        teams = initialize_teams()
        advancement_probs = create_realistic_advancement_probs(teams)
    end
    games = initialize_tournament_structure(teams)

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
    model = Model(HiGHS.Optimizer)
    
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
    
    # Seed-difference variable for upset detection in rounds 2-6
    @variable(model, -15 <= D[1:TOTAL_GAMES] <= 15)

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

            # Seed-difference upset detection
            @constraint(model, D[g] == sum(teams[t].seed * (2*w[g,t] - plays_in[g,t]) for t in 1:NUM_TEAMS))
            @constraint(model, D[g] <= 15 * is_upset[g])
            @constraint(model, D[g] >= 16 * is_upset[g] - 15)
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

    # Forced advancement constraints
    if forced_advancements !== nothing
        for (team_identifier, target_round) in forced_advancements
            team_id = resolve_team_id(teams, team_identifier)
            team = teams[team_id]
            println("  Forcing $(team.name) ($(team.region)$(team.seed)) to reach round $target_round")
            if target_round >= 2
                r = target_round - 1
                start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
                end_game = sum(GAMES_PER_ROUND[1:r])
                @constraint(model, sum(w[g, team_id] for g in start_game:end_game) >= 1)
            end
        end
    end

    # Cinderella variables
    if cinderella_mode
        @variable(model, 1 <= winner_seed[1:TOTAL_GAMES] <= 16)
        @variable(model, is_cinderella[1:TOTAL_GAMES], Bin)

        for g in 1:TOTAL_GAMES
            @constraint(model, winner_seed[g] == sum(teams[t].seed * w[g, t] for t in 1:NUM_TEAMS))
        end

        for r in 1:NUM_ROUNDS
            threshold = CINDERELLA_THRESHOLDS[r]
            start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
            end_game = sum(GAMES_PER_ROUND[1:r])
            for g in start_game:end_game
                @constraint(model, winner_seed[g] >= threshold + 1 - 16 * (1 - is_cinderella[g]))
                @constraint(model, winner_seed[g] <= threshold + 16 * is_cinderella[g])
            end
        end
    end

    # Apply quota constraints (upsets or cinderellas)
    if apply_upset_constraints
        quota_var = cinderella_mode ? is_cinderella : is_upset

        if upset_mode == :per_round
            for r in 1:NUM_ROUNDS
                start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
                end_game = sum(GAMES_PER_ROUND[1:r])
                min_count = ceil(Int, GAMES_PER_ROUND[r] * upset_prop)
                @constraint(model, sum(quota_var[g] for g in start_game:end_game) >= min_count)
            end
        elseif upset_mode == :per_region
            for region in REGIONS
                region_games = [g for g in 1:60 if games[g].region == region]
                min_count = ceil(Int, length(region_games) * upset_prop)
                @constraint(model, sum(quota_var[g] for g in region_games) >= min_count)
            end
            ff_games = [g for g in 61:63 if g <= TOTAL_GAMES]
            min_ff = ceil(Int, length(ff_games) * upset_prop)
            @constraint(model, sum(quota_var[g] for g in ff_games) >= min_ff)
        else
            error("Unknown upset_mode: $upset_mode. Valid: :per_round, :per_region")
        end
    end
    
    # Objective: Maximize expected score
    # Using Fibonacci sequence for scoring: 5, 8, 13, 21, 34, 55
    fibonacci = [5, 8, 13, 21, 34, 55]

    objective_expr = 0
    for r in 1:NUM_ROUNDS
        start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
        end_game = sum(GAMES_PER_ROUND[1:r])

        for g in start_game:end_game
            for t in 1:NUM_TEAMS
                objective_expr += advancement_probs[(t, r)] * (fibonacci[r] + teams[t].seed) * w[g, t]
            end
        end
    end

    @objective(model, Max, objective_expr)
    
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
    upsets_by_round = Dict{Int, Int}()
    cinderellas_by_round = Dict{Int, Int}()

    for r in 1:NUM_ROUNDS
        upsets_by_round[r] = 0
        cinderellas_by_round[r] = 0
        start_game = r == 1 ? 1 : sum(GAMES_PER_ROUND[1:(r-1)]) + 1
        end_game = sum(GAMES_PER_ROUND[1:r])

        for g in start_game:end_game
            for t in 1:NUM_TEAMS
                if value(w[g, t]) > 0.5
                    winners[g] = t
                    if value(is_upset[g]) > 0.5
                        upsets_by_round[r] += 1
                    end
                    if cinderella_mode && value(is_cinderella[g]) > 0.5
                        cinderellas_by_round[r] += 1
                    end
                    break
                end
            end
        end
    end

    score = calculate_bracket_score(winners, teams, advancement_probs)
    bracket = Bracket(winners, score, upsets_by_round, cinderellas_by_round)

    print_bracket(bracket, teams, games)
    analyze_bracket(bracket, teams, games)

    return bracket
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
                
                println("  Game $g: $(team_label(team1)) vs $(team_label(team2)) → $(team_label(winner)) advances$upset_str")
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
                    println("  Game $g: $(team_label(team1)) vs $(team_label(team2)) → $(team_label(winner)) CHAMPION$upset_str")
                else
                    println("  Game $g: $(team_label(team1)) vs $(team_label(team2)) → $(team_label(winner)) advances$upset_str")
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