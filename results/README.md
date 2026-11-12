# Results

The harness's records, one folder per workflow run and inside it one folder per group. Each record holds the race's
command, the commit it ran at, the runner, every entrant's times and measures, and whether the entrants gave the
same answers. `versions.tsv` beside the records says which release of each tool ran.

A group that was run again has records in more than one run, and the latest run is the one that counts.

| Run | What changed before it | Groups |
|---|---|---|
| 43205123597 | The first run | all ten |
| 43208936074 | Stopping waits for the server to be gone, and image sizes are measured by export | gateway, image |
| 43209389271 | The eval and the one-call client race time every entrant as a whole process | client, eval |
| 43210396930 | The race that times a start tries the port every 2 ms | gateway |

In run 43205123597 the harness refused two gateway races, because LiteLLM wasn't listening when its turn came.
