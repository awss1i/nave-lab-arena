# nave-lab-arena

Races between the prototypes of Nave, a gateway for model calls that is still being built, and the tools it overlaps
with. This repository holds the race files, the scripts that install each competitor, Nave's entrants as built
binaries, and the results. It holds none of Nave's source.

## How a race runs

Every race runs on a GitHub-hosted runner, started by the workflow in `.github/workflows/arena.yml`.

- **No real provider is called.** Every gateway and client talks to `bin/standin`, a stand-in model that answers
  "echo: " and the last message it was sent, whole or as a stream.
- **Each competitor is installed at its latest release** by a script in `setup/`, at the settings its own docs give
  for production, and its version is written to `results/versions.tsv`.
- **Answers are checked before times are kept.** `bin/race` runs every entrant of a race and compares what they
  print, which is how many answers were right and a checksum of all of them. A race whose entrants disagree is
  marked wrong and gets no time.
- **A runner has four CPUs.** The load tool gets one, the stand-in model one, and the tool being raced two.

## What's here

| Path | What it is |
|---|---|
| `arena.sh GROUP` | Installs a group's competitors, makes its inputs, and runs its races |
| `races/` | One file per group: each race's name, conditions, entrants and how many rounds |
| `setup/` | How each competitor is installed and started |
| `gateways.sh`, `entrant.sh` | Start the gateways, and run one entrant of one race |
| `clients/` | The same task written for each competing library |
| `data/` | Inputs: a prompt template, and real tool outputs from public repositories with paths rewritten |
| `bin/` | Static binaries: the harness, the stand-in model, the load tool, and Nave's prototypes |
| `results/` | The harness's records from each run |

## Groups

`gateway`, `cache`, `client`, `template`, `cost`, `config`, `eval`, `scan`, `compress`, `image`.

To run one yourself on Linux with Python, Node and Docker: `./arena.sh template`.
