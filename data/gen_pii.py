"""Writes prompts with made-up personal data planted in ordinary sentences, and the list of what was planted.
Usage: gen_pii.py OUT_DIR [PROMPTS]. The values are random, in each kind's shape, and belong to nobody: card numbers
pass the Luhn check and start with test prefixes, and addresses use example.com and documentation IP ranges.
It writes OUT_DIR/pii.txt for Nave's p011 (each prompt after a line with its length in bytes), OUT_DIR/pii.jsonl
with one prompt a line for the other tools, and OUT_DIR/pii-planted.tsv."""
import json
import random
import sys

random.seed(20261113)
out, prompts = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 2000
digits = lambda n: "".join(random.choice("0123456789") for _ in range(n))


def card():
    body = random.choice(["4242", "4000", "5555"]) + digits(11)
    total = sum(sum(divmod(int(c) * 2, 10)) if i % 2 == 0 else int(c) for i, c in enumerate(reversed(body)))
    number = body + str((10 - total % 10) % 10)
    return " ".join(number[i:i + 4] for i in range(0, 16, 4)) if random.random() < 0.5 else number


def ssn():
    return f"{random.randint(100, 665):03d}-{random.randint(10, 99):02d}-{random.randint(1000, 9999):04d}"


kinds = {
    "email": lambda: f"{random.choice(['ana', 'li.wei', 'j_smith', 'support+eu', 'noor'])}{random.randint(1, 9999)}@{random.choice(['example.com', 'mail.example.org', 'corp.example.net'])}",
    "card_number": card,
    "us_ssn": ssn,
    "ipv4": lambda: f"{random.choice(['192.0.2', '198.51.100', '203.0.113'])}.{random.randint(1, 254)}",
}
carriers = {
    "email": ["Please send the invoice to {v} before Friday.", "The account is registered under {v} and needs a reset.", "Reply to {v} with the tracking number."],
    "card_number": ["The card on file is {v} and it was declined twice.", "Charge the renewal to {v}, expiry next year.", "Customer read out {v} over the phone."],
    "us_ssn": ["Her social security number is {v}, as on the form.", "SSN {v} was entered for the background check.", "The applicant gave {v} as their SSN."],
    "ipv4": ["The request came from {v} at midnight.", "Block {v} at the firewall until we know more.", "Logs show {v} retrying every second."],
}
prose = ["The build finished in {n} minutes and every test passed on the second try.", "Ticket {n} was reopened because the export still times out for large accounts.",
         "We moved the nightly job to {n}:30 so it no longer overlaps with the backup.", "Latency at the 99th percentile was {n} ms after the change, down from last week.",
         "Please review the pull request before Thursday, it touches {n} files in the billing module.", "Order {n} shipped in two boxes and the second one is still in transit.",
         "The meeting moved to room {n} because the projector there works.", "Version {n}.4 fixes the crash on export and adds a dark theme."]
texts, planted = [], []
for p in range(prompts):
    lines = [random.choice(prose).format(n=random.randint(2, 900)) for _ in range(random.randint(18, 30))]
    for _ in range(2):
        kind = random.choice(list(kinds))
        value = kinds[kind]()
        planted.append(f"{p}\t{kind}\t{value}")
        lines.insert(random.randint(0, len(lines)), random.choice(carriers[kind]).format(v=value))
    texts.append(" ".join(lines))
with open(f"{out}/pii.txt", "wb") as f:
    for t in texts:
        b = t.encode()
        f.write(f"{len(b)}\n".encode() + b)
with open(f"{out}/pii.jsonl", "w") as f:
    for t in texts:
        f.write(json.dumps(t) + "\n")
open(f"{out}/pii-planted.tsv", "w").write("\n".join(planted) + "\n")
print(f"{len(planted)} values planted in {prompts} prompts, {sum(len(t.encode()) for t in texts)} bytes")
