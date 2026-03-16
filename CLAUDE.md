# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Julia package that uses Integer Linear Programming (ILP) to optimize NCAA March Madness bracket picks, maximizing expected score given seed-based advancement probabilities and optional tournament constraints.

## Common Commands

### Run the optimizer
```julia
# Start Julia with the project environment
julia --project=.

# In Julia REPL:
using MarchMadnessOptimizer
bracket, teams, games = run_tournament_optimization()

# With custom Final Four constraints
bracket = run_with_custom_final_four(
    final_four_teams=Dict("E"=>1, "MW"=>8, "S"=>3, "W"=>10),
    apply_upset_constraints=true,
    upset_prop=0.5
)
```

### Install dependencies
```julia
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

### Run tests
```julia
julia --project=. test/runtests.jl
```

### Run the example vignette
```julia
julia --project=. examples/vignette.jl
```

## Architecture

All logic lives in a single file: `src/MarchMadnessOptimizer.jl`.

### Data Structures
- **`Team`**: `id`, `region` (E/W/MW/S), `seed` (1–16), `name`
- **`Game`**: `id`, `round` (1–6), `region`, `team_ids`, `next_game_id` (which game the winner advances to)
- **`Bracket`**: `winners` dict (game_id → team_id), `score`, `upsets` dict

### Tournament Structure (63 games)
- Games 1–32: First Round
- Games 33–48: Second Round
- Games 49–56: Sweet 16
- Games 57–60: Elite 8
- Games 61–62: Final Four (61: E vs MW, 62: W vs S)
- Game 63: Championship

### Optimization Model (JuMP + GLPK)
- **Decision variables**: `w[g,t]` — binary, team `t` wins game `g`
- **Objective**: maximize expected score = Σ (Fibonacci weight for round × team seed) × advancement probability
- **Fibonacci round weights**: `[5, 8, 13, 21, 34, 55]` for rounds 1–6
- **Key constraints**:
  - First-round matchups are fixed by standard NCAA seeding
  - Winner of game `g` must have won the prerequisite feeder game
  - Optional: upset percentage bounds per round
  - Optional: force specific teams to reach Final Four or win championship

### Key Functions
| Function | Purpose |
|---|---|
| `initialize_teams()` | Creates 64 teams (4 regions × 16 seeds) |
| `create_first_round_matchups()` | Wires up seed-based first-round pairings |
| `initialize_tournament_structure()` | Builds all 63 games with advancement links |
| `create_realistic_advancement_probs()` | Assigns seed-based win probabilities |
| `optimize_bracket()` | Core ILP solver; accepts constraint options |
| `run_tournament_optimization()` | Top-level entry point |
| `run_with_custom_final_four()` | Entry point with Final Four/championship constraints |
| `calculate_bracket_score()` | Computes expected score for a solved bracket |
| `print_bracket()` / `analyze_bracket()` | Display and analysis utilities |

### Advancement Probability Model
Probabilities are determined by seed rank (1 = strongest). Teams with lower seed numbers (higher seeds) receive higher probabilities, modeled to reflect historical NCAA upset rates. Default upset proportion can be tuned via `upset_prop` parameter.
