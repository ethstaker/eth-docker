# End-to-End Testing Guide

This document covers how to run end-to-end tests for the DNS updater with both Route53 and Cloudflare providers, including corner cases and expected failure modes.

## Architecture Overview

```
updater.py              ← main loop, IP fetching, signal handling
base.py                 ← DNSProvider ABC, registry, build_provider()
route53_provider.py     ← Route53Provider + AwsCredentialResolver
cf_provider.py          ← CloudflareProvider
privilege.py            ← PrivilegeManager (root-only: copy_aws_config, drop)
```

**Import graph** (no cycles):
```
updater.py → base.py, privilege.py, route53_provider.py, cf_provider.py
route53_provider.py → base.py
cf_provider.py → base.py
```

## Prerequisites

### Docker (required for privilege management)

The container must start as `root` so it can:
1. Copy `/root/.aws` (mounted from host) into the target user's home
2. `chown` and set permissions on the copied files
3. Drop privileges to the `RUN_AS_USER` (default: `dns`)

### Environment Variables

| Variable | Route53 | Cloudflare | Required |
|---|---|---|---|
| `DNS_PROVIDER` | `route53` | `cloudflare` | No (default: `route53`) |
| `AWS_HOSTED_ZONE_ID` | `Z0123456789` | — | Yes (Route53) |
| `AWS_ACCESS_KEY_ID` | `AKIA...` | — | Yes if no profile |
| `AWS_SECRET_ACCESS_KEY` | `...` | — | Yes if no profile |
| `AWS_PROFILE` | `myprofile` | — | Optional (alternative to keys) |
| `DDNS_HOST` | `host` | `host` | Yes |
| `DOMAIN` | `example.com` | `example.com` | Yes |
| `CNAME_LIST` | `api, www` | `api, www` | No (default: `""`) |
| `TTL` | `300` | `300` | No (default: `300`) |
| `SLEEP` | `300` | `300` | No (default: `300`) |
| `CF_ZONE_ID` | — | `abc123` | Yes (Cloudflare) |
| `CF_DNS_API_TOKEN` | — | `token...` | Yes (Cloudflare) |
| `CF_ZONE_API_TOKEN` | — | `token...` | No (defaults to write token) |
| `RUN_AS_USER` | `dns` | `dns` | No (default: `dns`) |
| `LOG_LEVEL` | `DEBUG` | `DEBUG` | No (default: `INFO`) |

---

## Route53 Tests

### Test 1: Profile-based auth (typical production)

```bash
docker run -e DNS_PROVIDER=route53 \
           -e AWS_PROFILE=myprofile \
           -e AWS_HOSTED_ZONE_ID=Z0123456789 \
           -e DDNS_HOST=test \
           -e DOMAIN=example.com \
           -e CNAME_LIST=api,www \
           -v ~/.aws:/root/.aws:ro \
           your-image
```

**Expected:**
- Log: `Using AWS profile 'myprofile' from ~/.aws/credentials`
- Log: `AWS identity: arn:aws:iam::... (Account ...)`
- A record created/updated for `test.example.com.`
- CNAMEs created/updated for `api.example.com.` and `www.example.com.`
- Container runs indefinitely, logging "Sleeping 300 seconds" between cycles

### Test 2: Direct key auth

```bash
docker run -e DNS_PROVIDER=route53 \
           -e AWS_ACCESS_KEY_ID=AKIA... \
           -e AWS_SECRET_ACCESS_KEY=... \
           -e AWS_HOSTED_ZONE_ID=Z0123456789 \
           -e DDNS_HOST=test \
           -e DOMAIN=example.com \
           your-image
```

**Expected:**
- Log: `Using AWS credentials from environment variables.`
- `AWS_PROFILE` is unset from the environment before session creation
- Same record update behavior as Test 1

### Test 3: Default profile fallback

```bash
docker run -e DNS_PROVIDER=route53 \
           -e AWS_HOSTED_ZONE_ID=Z0123456789 \
           -e DDNS_HOST=test \
           -e DOMAIN=example.com \
           -v ~/.aws:/root/.aws:ro \
           your-image
```

Set up `~/.aws/credentials` with a `[default]` profile and no `AWS_PROFILE` env var.

**Expected:**
- Log: `Using default AWS profile from ~/.aws/credentials`

---

## Cloudflare Tests

### Test 4: Valid tokens

```bash
docker run -e DNS_PROVIDER=cloudflare \
           -e CF_ZONE_ID=abc123 \
           -e CF_DNS_API_TOKEN=write-token \
           -e CF_ZONE_API_TOKEN=read-token \
           -e DDNS_HOST=test \
           -e DOMAIN=example.com \
           your-image
```

**Expected:**
- Log: Cloudflare validation succeeds (no STS call)
- A/AAAA/CNAME records managed via Cloudflare API
- No AWS-related log messages

### Test 5: Read token omitted (falls back to write token)

```bash
docker run -e DNS_PROVIDER=cloudflare \
           -e CF_ZONE_ID=abc123 \
           -e CF_DNS_API_TOKEN=write-token \
           -e DDNS_HOST=test \
           -e DOMAIN=example.com \
           your-image
```

**Expected:** Same behavior as Test 4; `CF_ZONE_API_TOKEN` defaults to write token value.

---

## Corner Case Tests

### Test 6: Apex CNAME rejection (Route53 only)

CNAME_LIST labels always get `.$DOMAIN` appended, so they can never match the zone
apex. The `allows_apex_cname` guard is a safety net for future provider-level logic;
it cannot be triggered via CNAME_LIST.

### Test 7: No external IPv6

Run on a host/container without IPv6 connectivity.

**Expected:**
- `get_external_ip6()` returns `None` after exhausting all services
- Log: `No external IPv6 detected; skipping AAAA update`
- Log: `Skipping AAAA update: no external IPv6 detected`
- A record and CNAMEs still updated

### Test 8: Record already correct (no-op cycle)

After a successful first run, let the loop execute again without IP changes.

**Expected:**
- Log: `A record test.example.com. already up-to-date with IP x.x.x.x`
- Log: `CNAME api.example.com. already points to test.example.com.`
- No `change_resource_record_sets` API calls (skipped by `record_is` check)

### Test 9: Short label expansion

```bash
-e DDNS_HOST=test -e DOMAIN=example.com -e CNAME_LIST=api,cdn
```

**Expected:**
- `api` → `api.example.com.`
- `cdn` → `cdn.example.com.`

### Test 10: Labels always get DOMAIN appended

```bash
-e DDNS_HOST=test -e DOMAIN=example.com -e CNAME_LIST=api,cdn
```

**Expected:**
- `api` → `api.example.com.`
- `cdn` → `cdn.example.com.`

---

## Expected Failure Modes

### Test 11: No AWS credentials at all

```bash
docker run -e DNS_PROVIDER=route53 \
           -e AWS_HOSTED_ZONE_ID=Z0123456789 \
           -e DDNS_HOST=test \
           -e DOMAIN=example.com \
           your-image
```

No env vars, no mounted `.aws` directory.

**Expected:**
- `RuntimeError: No valid AWS credentials found (env vars or ~/.aws/credentials)`
- Container exits with non-zero code
- No privilege drop attempted (fails during credential resolution)

### Test 12: Missing required env var

```bash
docker run -e DNS_PROVIDER=route53 \
           -e DDNS_HOST=test \
           -e DOMAIN=example.com \
           your-image
```

Missing `AWS_HOSTED_ZONE_ID`.

**Expected:**
- `KeyError: 'AWS_HOSTED_ZONE_ID'`
- Container exits with traceback

### Test 13: Invalid AWS credentials

Mount a profile with expired/invalid keys.

**Expected:**
- `RuntimeError: Route53 validation failed: An error occurred (InvalidClientTokenId) ...`
- Container exits (error raised in `build_provider` before the main loop)

### Test 14: Non-existent hosted zone

```bash
docker run -e DNS_PROVIDER=route53 \
           -e AWS_HOSTED_ZONE_ID=ZINVALID \
           -e AWS_ACCESS_KEY_ID=AKIA... \
           -e AWS_SECRET_ACCESS_KEY=... \
           -e DDNS_HOST=test \
           -e DOMAIN=example.com \
           your-image
```

**Expected:**
- `RuntimeError: Route53 validation failed: An error occurred (NoSuchHostedZone) ...`
- Container exits before entering the update loop

### Test 15: Invalid Cloudflare token

```bash
docker run -e DNS_PROVIDER=cloudflare \
           -e CF_ZONE_ID=abc123 \
           -e CF_DNS_API_TOKEN=invalid-token \
           -e DDNS_HOST=test \
           -e DOMAIN=example.com \
           your-image
```

**Expected:**
- `RuntimeError: Cloudflare validation failed: ...`
- Container exits before entering the update loop

### Test 16: Missing Cloudflare required vars

```bash
docker run -e DNS_PROVIDER=cloudflare \
           -e DDNS_HOST=test \
           -e DOMAIN=example.com \
           your-image
```

**Expected:**
- `KeyError: 'CF_ZONE_ID'` or `KeyError: 'CF_DNS_API_TOKEN'`
- Container exits with traceback

### Test 17: Unknown provider

```bash
docker run -e DNS_PROVIDER=bind \
           -e DDNS_HOST=test \
           -e DOMAIN=example.com \
           your-image
```

**Expected:**
- `SystemExit: Unknown DNS_PROVIDER=bind`
- Clean exit, no traceback

### Test 18: Network failure during IP fetch

Block outbound HTTPS (or set `SLEEP=1` and temporarily block network).

**Expected:**
- tenacity retries up to 5 times with exponential backoff (2s, 4s, 8s, 10s, 10s)
- After exhaustion: `requests.RequestException: Unable to fetch external IP from any source`
- Error caught in main loop, logged, container **continues** to next cycle
- No record updates attempted

### Test 19: API error during record check

Temporarily revoke Route53 permissions after startup.

**Expected (current behavior — fail-open):**
- `record_is` catches `ClientError`, logs the error, returns `True` (skip update)
- Log: `Error checking test.example.com. A: ... (AccessDenied)`
- Main loop continues; no upsert attempted for that record
- Other records (if any) in the same cycle are not affected

### Test 20: Alias record / multi-value record

Create an ALIAS or multi-value A record manually in the hosted zone.

**Expected:**
- Log: `Record test.example.com. A is an alias; skipping management.` (or `has multiple values`)
- `record_is` returns `True` — no upsert attempt
- Record is left untouched

### Test 21: Signal handling

```bash
# After container is running:
docker kill --signal=SIGTERM <container>
docker kill --signal=SIGINT <container>
```

**Expected:**
- Log: `Received shutdown signal, exiting.`
- Container exits with code 0
- Clean shutdown, no partial updates

---

## Quick Smoke Test (no AWS/CF needed)

Validate that the import chain and registry work without cloud credentials:

```bash
python3 -c "
from base import _PROVIDER_REGISTRY, build_provider
from privilege import PrivilegeManager
import route53_provider
import cf_provider

print('Registry:', _PROVIDER_REGISTRY)
assert 'route53' in _PROVIDER_REGISTRY
assert 'cloudflare' in _PROVIDER_REGISTRY
print('Registry check: OK')
"
```

## Debug Tips

1. Set `LOG_LEVEL=DEBUG` to see credential file paths and per-service IP fetch failures
2. Run with `SLEEP=5` for rapid iteration during testing
3. The first cycle runs immediately; subsequent cycles wait `SLEEP` seconds
4. AWS credential file ownership/perms are set to `700/600` — verify with `ls -la /home/dns/.aws/` inside the container
5. `build_provider` does a `is cls is Route53Provider` check — adding new providers with AWS dependencies requires updating this check in `base.py`
