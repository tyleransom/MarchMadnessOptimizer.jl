# MarchMadnessOptimizer.jl

A Julia package that uses Integer Linear Programming (ILP) to optimize NCAA March Madness bracket picks, maximizing expected score under pool-specific scoring and constraint rules.

## Pool Rules

**Pool Type:** Private (1 bracket per player)

### Scoring

Each correct pick earns base points for the round plus a seed bonus equal to the winning team's seed number.

| Round          | Base Points | Bonus        |
|----------------|-------------|--------------|
| First Round    | 5           | + Seed       |
| Second Round   | 8           | + Seed       |
| Sweet 16       | 13          | + Seed       |
| Elite 8        | 21          | + Seed       |
| Final Four     | 34          | + Seed       |
| Championship   | 55          | + Seed       |

For example, correctly picking a 12-seed to win in the Sweet 16 earns 13 + 12 = 25 points, while a 1-seed winning the same game earns 13 + 1 = 14 points.

**Tiebreaker:** Championship game's total score.

### Upset Constraint

At least half (defined as greater than or equal to 50%) of your choices in each round must be upsets (defined as a *lower* seed number winning).

A reminder: among other things this means that you cannot have both teams with the same seed number in the championship game, as it is impossible for one of them to upset the other.
