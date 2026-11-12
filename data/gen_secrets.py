"""Writes a text with made-up secrets planted in ordinary lines, and the list of what was planted.
Usage: gen_secrets.py OUT_DIR. The secrets are random strings in each kind's shape and belong to no account."""
import random
import sys

random.seed(20261112)
out = sys.argv[1]
ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
pick = lambda chars, n: "".join(random.choice(chars) for _ in range(n))
kinds = {
    "aws_access_key": lambda: "AKIA" + pick("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", 16),
    "github_token": lambda: "ghp_" + pick(ALNUM, 36),
    "slack_token": lambda: f"xoxb-{pick('0123456789', 12)}-{pick('0123456789', 13)}-{pick(ALNUM, 24)}",
    "stripe_key": lambda: "sk_live_" + pick(ALNUM, 24),
}
prose = ["The build finished in {n} minutes and every test passed on the second try.", "Ticket {n} was reopened because the export still times out for large accounts.",
         "We moved the nightly job to {n}:30 so it no longer overlaps with the backup.", "Latency at the 99th percentile was {n} ms after the change, down from last week.",
         "Please review the pull request before Thursday, it touches {n} files in the billing module."]
lines, planted = [], []
for i in range(400_000):
    lines.append(random.choice(prose).format(n=random.randint(2, 900)))
    if i % 200 == 100:
        kind = list(kinds)[(i // 200) % len(kinds)]
        secret = kinds[kind]()
        planted.append(f"{kind}\t{secret}")
        lines.append(random.choice([f'export TOKEN="{secret}"', f"key = {secret}", f"  api_key: '{secret}'", f"curl -H 'Authorization: Bearer {secret}' https://api.internal/v1"]))
open(f"{out}/secrets.txt", "w").write("\n".join(lines) + "\n")
open(f"{out}/planted.tsv", "w").write("\n".join(planted) + "\n")
print(f"{len(planted)} secrets planted in {sum(len(l) + 1 for l in lines)} bytes")
