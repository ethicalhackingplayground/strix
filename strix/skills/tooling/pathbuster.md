---
name: pathbuster
description: Pathbuster target syntax, traversal strategies, filtering, and common path-normalization enumeration workflows.
---

# Pathbuster CLI Playbook

Official docs:
- https://github.com/ethicalhackingplayground/pathbuster

## What is Pathbuster?

Pathbuster is a path-normalization pentesting tool written in Rust, inspired by FFUF. It is designed to discover and exploit path-normalization vulnerabilities in web applications — situations where a server normalizes URL paths in a way that can be abused to bypass access controls, reach hidden endpoints, or traverse restricted directories.

It works by injecting traversal payloads (e.g. `../`, `..%2f`, encoded variants) into paths at varying depths, then optionally bruteforcing discovered paths with a wordlist. Pathbuster auto-fingerprints WAF/tech stacks and can apply bypass transforms accordingly.

Canonical syntax:
`pathbuster --url "<target_url>" --payloads <payload_file> [options]`

Installation:
```
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cargo install pathbuster
```

## High-signal flags

- `-u, --url <URL>` target URL (repeatable for multiple targets)
- `-i, --input-file <FILE>` load targets from file (one per line)
- `--payloads <FILE>` traversal payload file (one payload per line)
- `--wordlist <FILE>` bruteforce wordlist for discovery phase
- `--path <PATH>` scan a single path instead of a wordlist
- `--raw-request <FILE>` raw HTTP request template with `*` as injection points
- `--skip-brute` skip the bruteforce/discovery phase (traversal-only)
- `-s, --skip-validation` skip validation phase and go straight to bruteforce
- `-r, --rate <RPS>` request rate limit (requests per second)
- `-t, --concurrency <N>` max in-flight concurrent requests
- `--timeout <SECONDS>` per-request timeout
- `-p, --proxy <URL>` HTTP proxy (e.g. Burp Suite at `http://127.0.0.1:8080`)
- `--header <KEY: VALUE>` add a custom header to all requests (repeatable)
- `-m, --methods <METHODS>` comma-separated HTTP methods (e.g. `GET,POST`)
- `--follow-redirects` follow HTTP redirects
- `--validate-status, --vs <CODES>` status codes that signal a valid/protected endpoint in validation phase
- `--fingerprint-status <CODES>` status codes used to fingerprint traversal depth
- `--wordlist-status, --ws <CODES>` allowed status codes for bruteforce findings
- `--drop-after-fail <CODES>` stop scanning a target after repeated matching status codes
- `--response-diff-threshold, --rdt <MIN-MAX>` response diff range for comparisons (e.g. `5-1000`)
- `--start-depth <N>` initial traversal depth
- `--max-depth <N>` maximum traversal depth
- `-X, --traversal-strategy, --ts <greedy|quick>` traversal strategy selection
- `--bypass-level <0-3>` WAF bypass aggressiveness level
- `--bypass-transform <NAME>` force specific payload transform families (repeatable)
- `--disable-waf-bypass` disable WAF-aware payload transformations
- `--disable-fingerprinting` disable WAF/tech fingerprinting
- `--filter-status <SET>` exclude by HTTP status with stage prefix (e.g. `V:404,F:500`)
- `--filter-size <SET>` exclude by body size with stage prefix (e.g. `V:1234,F:5678`)
- `--filter-words <SET>` exclude by word count with stage prefix (e.g. `V:10,F:25`)
- `--filter-lines <SET>` exclude by line count with stage prefix (e.g. `V:5,F:20`)
- `--filter-regex <STAGE:REGEX>` exclude responses matching regex per stage (repeatable)
- `--disable-show-all, --dsa` only show findings matching `--wordlist-status`
- `--wordlist-manipulation, --wm <LIST>` comma-separated wordlist transforms (see Wordlist Manipulation)
- `--brute-queue-concurrency, --bqc <N>` max base URLs per bruteforce batch (0 = no batching)
- `--ac` enable automatic collaboration/noise filtering during bruteforce
- `-C, --config <FILE>` config file path (defaults to `~/.pathbuster/config.yml`)
- `-o, --output <FILE>` write results to a file
- `--output-format <text|json|xml|html>` output format
- `-v, --verbose` increase verbosity (`-v`, `-vv`)

## Traversal Strategies

### Greedy (default)
Probes depths from `--start-depth` up to `--max-depth` to find where `--fingerprint-status` matches, then validates back toward start. Higher request count but more thorough — best when the target's normalization behavior is unknown.

### Quick
Computes fingerprint depth directly from the target URL path segment count plus `--start-depth`. Validates a minimal set of depths for speed. Best when the base URL has meaningful path segments (e.g. `https://example.com/app/`).

## Agent-safe baseline for automation

```
pathbuster \
  --url "https://target.tld/app/" \
  --payloads ./payloads/traversals.txt \
  --wordlist ./wordlists/wordlist.txt \
  --rate 100 \
  --concurrency 50 \
  --timeout 10 \
  --traversal-strategy quick \
  --validate-status 404 \
  --fingerprint-status 400,500
```

## Common patterns

- Basic traversal + bruteforce:
  ```
  pathbuster --url "https://target.tld/app/" \
    --payloads ./payloads/traversals.txt \
    --wordlist ./wordlists/wordlist.txt
  ```

- Traversal-only (no bruteforce):
  ```
  pathbuster --url "https://target.tld/app/" \
    --payloads ./payloads/traversals.txt \
    --wordlist ./wordlists/wordlist.txt \
    --skip-brute
  ```

- Single path traversal check:
  ```
  pathbuster --url "https://target.tld/app/" \
    --payloads ./payloads/traversals.txt \
    --path internal/admin \
    --skip-brute
  ```

- Scan with multiple HTTP methods:
  ```
  pathbuster --url "https://target.tld/app/" \
    --methods GET,POST \
    --payloads ./payloads/traversals.txt \
    --wordlist ./wordlists/wordlist.txt
  ```

- Authenticated scan with custom headers:
  ```
  pathbuster --url "https://target.tld/app/" \
    --payloads ./payloads/traversals.txt \
    --wordlist ./wordlists/wordlist.txt \
    --header "Authorization: Bearer <token>" \
    --header "X-Custom: value"
  ```

- Proxy through Burp Suite:
  ```
  pathbuster --url "https://target.tld/app/" \
    --payloads ./payloads/traversals.txt \
    --wordlist ./wordlists/wordlist.txt \
    --proxy http://127.0.0.1:8080
  ```

- Raw HTTP request with injection points:
  ```
  pathbuster --url "https://target.tld/app/" \
    --raw-request ./request.txt \
    --payloads ./payloads/traversals.txt \
    --wordlist ./wordlists/wordlist.txt
  ```
  (request.txt uses `*` as injection markers, e.g. `GET /app/* HTTP/1.1`)

- Explicit depth and status tuning:
  ```
  pathbuster --url "https://target.tld/app/" \
    --payloads ./payloads/traversals.txt \
    --wordlist ./wordlists/wordlist.txt \
    --validate-status 404 \
    --fingerprint-status 400,500 \
    --start-depth 0 \
    --max-depth 5 \
    --response-diff-threshold 5-1000 \
    --filter-status V:301,302,F:404
  ```

- WAF bypass with bypass-level escalation:
  ```
  pathbuster --url "https://target.tld/app/" \
    --payloads ./payloads/traversals.txt \
    --wordlist ./wordlists/wordlist.txt \
    --bypass-level 3
  ```

- Output results to JSON:
  ```
  pathbuster --url "https://target.tld/app/" \
    --payloads ./payloads/traversals.txt \
    --wordlist ./wordlists/wordlist.txt \
    --output ./results.json \
    --output-format json
  ```

- Multiple targets from file:
  ```
  pathbuster --input-file ./targets.txt \
    --payloads ./payloads/traversals.txt \
    --wordlist ./wordlists/wordlist.txt
  ```

## Wordlist Manipulation

`--wordlist-manipulation <LIST>` (alias `--wm`) applies transforms to the bruteforce wordlist before scanning.
`LIST` is a comma-separated combination of:

- `sort` — sort alphabetically (also deduplicates when combined with `unique`)
- `unique` / `uniq` — deduplicate words
- `reverse` / `rev` — reverse each word
- `lower` — lowercase each word
- `upper` — uppercase each word
- `title` — title-case each word
- `prefix=<STR>` — prefix each word
- `suffix=<STR>` — suffix each word
- `replace=<FROM:TO>` — replace substring
- `smart` — split naming conventions into separate words (`AdminPanel` → `Admin`, `Panel`)
- `smartjoin=<CASE:SEP>` — split then rejoin (`smartjoin=l:_` turns `AdminPanel` → `admin_panel`)

## Stage prefix reference for filters

Filters support a `V:` (validation phase) and `F:` (fingerprint phase) prefix to scope exclusions. Omitting the prefix applies to both stages.

- `V:404` — filter 404s during validation only
- `F:500` — filter 500s during fingerprinting only
- `V:404,F:500` — filter 404 in validation and 500 in fingerprinting

## Critical correctness rules

- Always provide `--payloads` — this is the traversal payload file and is required for traversal logic.
- Always provide `--wordlist` or `--path` — required for the bruteforce phase unless `--skip-brute` is set.
- Use `--skip-brute` to confirm traversal exploitability before running a full bruteforce.
- Prefer `--traversal-strategy quick` for speed when the base URL has meaningful path structure.
- Use `--traversal-strategy greedy` when the target's normalization behavior is unknown.
- Start conservative (`--rate 50-100`, `--bypass-level 0-1`) and escalate only when needed.
- Scope filters with stage prefixes (`V:`/`F:`) to avoid masking findings in the wrong phase.

## Usage rules

- Keep `--header` aligned with any authenticated session state from manual validation.
- Prefer `--path` over `--wordlist` when targeting a specific known endpoint.
- Use `--disable-show-all` with `--wordlist-status` to reduce noise and only surface relevant findings.
- Use `--drop-after-fail` to skip unresponsive or blocking targets early.
- Use `--proxy` to pipe all traffic through Burp Suite for manual review alongside automated scanning.

## Failure recovery

- If traversal produces no results, try increasing `--max-depth` incrementally or switching to `--traversal-strategy greedy`.
- If filtered/blocked by a WAF, increase `--bypass-level` (0 → 1 → 2 → 3) and test `--bypass-transform` chains.
- If results are noisy, tune `--filter-status`, `--filter-size`, `--filter-words`, or `--response-diff-threshold`.
- If status matching is off, adjust `--validate-status` and `--fingerprint-status` to match what the target returns for protected/missing routes.
- If bruteforce phase is slow, tune `--brute-queue-concurrency` and enable `--ac` to auto-filter noise.

If uncertain, query web_search with:
`site:github.com/ethicalhackingplayground/pathbuster pathbuster <flag>`
