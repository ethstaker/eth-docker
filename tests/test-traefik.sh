#!/usr/bin/env bash
#
# Test script for the DNS updater (Route53 + Cloudflare providers).
#
# Usage:
#   ./test-traefik.sh [--route53] [--cloudflare] [--both] [--dry-run]
#
# Defaults to --both if no provider flag is given.
#
# Assumes:
#   - This script lives in <project>/tests
#   - <project>/.env exists with real credentials filled in
#
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
eth_docker_dir="${script_dir}/.."
env_file="${eth_docker_dir}/.env"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
nc='\033[0m'

test_r53=false
test_cf=false
dry_run=false

for arg in "$@"; do
  case "$arg" in
    --route53)  test_r53=true ;;
    --cloudflare) test_cf=true ;;
    --both)     test_r53=true; test_cf=true ;;
    --dry-run)  dry_run=true ;;
    --help|-h)
      echo "Usage: $0 [--route53] [--cloudflare] [--both] [--dry-run]"
      exit 0
      ;;
    *)
      echo -e "${red}Unknown argument: $arg${nc}" >&2
      exit 1
      ;;
  esac
done

if [[ "$test_r53" == false && "$test_cf" == false ]]; then
    test_r53=true
    test_cf=true
fi

log_pass() { echo -e "  ${green}✓${nc} $1"; }
log_fail() { echo -e "  ${red}✗${nc} $1"; }
log_info() { echo -e "  $1"; }
log_section() { echo -e "\n${yellow}--- $1 ---${nc}"; }

env_var() {
  local var="$1"
  if [[ ! -f "$env_file" ]]; then
    echo ""
    return
  fi
  grep -E "^${var}=" "$env_file" | head -1 | cut -d'=' -f2- | sed 's/[[:space:]]*$//' | sed "s/^['\"]//;s/['\"]$//"
}

has_real_value() {
  local val
  val="$(env_var "$1")"
  [[ -n "$val" && "$val" != "SECRETTOKEN" && "$val" != "example.com" && "$val" != "user@example.com" ]]
}

# Build the ddns service image via the actual compose file
build_ddns() {
  local compose_file="$1"
  log_section "Building ddns image via ${compose_file}"
  if $dry_run; then
    echo "  (dry-run: docker compose -f ${compose_file} --env-file ${env_file} build ddns)"
    return 0
  fi
  docker compose -f "${compose_file}" --env-file "${env_file}" build ddns 2>&1
}

# Run the ddns service with timeout. Compose interpolates .env vars;
# any -e flags passed here override them in the container.
run_ddns() {
  local compose_file="$1"
  local timeout_sec="${2:-20}"
  shift 2

  if $dry_run; then
    echo "  (dry-run: docker compose -f ${compose_file} --env-file ${env_file} run --rm ddns $*)"
    echo "(dry-run output placeholder)"
    return 0
  fi

  timeout "${timeout_sec}" docker compose \
    -f "${compose_file}" \
    --env-file "${env_file}" \
    run --rm ddns "$@" 2>&1 || true
}

# ============================================================================
# Prerequisite checks
# ============================================================================

echo -e "\n${yellow}[setup]${nc} Checking prerequisites..."

if [[ ! -f "$eth_docker_dir/ethd" ]]; then
  echo -e "${red}eth-docker directory not found at ${eth_docker_dir}${nc}" >&2
  exit 1
fi
log_pass "Found eth-docker at ${eth_docker_dir}"

if [[ ! -f "$env_file" ]]; then
  echo -e "${red}.env not found at ${env_file}${nc}" >&2
  exit 1
fi
log_pass "Found .env file"

if ! command -v docker &>/dev/null; then
  echo -e "${red}docker not found in PATH${nc}" >&2
  exit 1
fi
log_pass "docker is available"

if ! docker compose version &>/dev/null; then
  echo -e "${red}docker compose not available${nc}" >&2
  exit 1
fi
log_pass "docker compose is available"

# ============================================================================
# Route53 Tests
# ============================================================================

compose_aws="${eth_docker_dir}/traefik-aws.yml"

if $test_r53; then
  echo -e "\n========================================"
  echo -e "  Route53 Provider Tests"
  echo -e "========================================"

  r53_can_run=true

  HZ_ID="$(env_var AWS_HOSTED_ZONE_ID)"

  if [[ -z "$HZ_ID" || "$HZ_ID" == *"example"* ]]; then
    log_fail "AWS_HOSTED_ZONE_ID is not configured"
    r53_can_run=false
  else
    log_pass "AWS_HOSTED_ZONE_ID is set (${HZ_ID})"
  fi

  has_profile=false
  has_keys=false

  if has_real_value AWS_PROFILE; then
    has_profile=true
    log_pass "AWS_PROFILE is set ($(env_var AWS_PROFILE))"
  fi

  if has_real_value AWS_ACCESS_KEY_ID && has_real_value AWS_SECRET_ACCESS_KEY; then
    has_keys=true
    log_pass "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY are set"
  fi

  if ! $has_profile && ! $has_keys; then
    log_fail "No valid AWS auth (need AWS_PROFILE or AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY)"
    r53_can_run=false
  fi

  if [[ ! -f "$compose_aws" ]]; then
    log_fail "traefik-aws.yml not found at ${compose_aws}"
    r53_can_run=false
  fi

  if ! $r53_can_run; then
    echo -e "\n${yellow}Route53 tests skipped — missing credentials or compose file.${nc}"
    echo "  Fill in the relevant variables in ${env_file} and re-run."
  else
    build_ddns "$compose_aws"

    # Test 1: Basic update cycle
    # Compose interpolates DDNS_HOST, DOMAIN, credentials, CNAME_LIST from .env.
    # We only override test-specific vars.
    log_section "Test: Route53 basic update cycle"

    output=$(run_ddns "$compose_aws" 20 \
      -e "SLEEP=2" \
      -e "TTL=60" \
      -e "LOG_LEVEL=debug")

    if echo "$output" | grep -q "Updated A record"; then
      log_pass "A record was updated"
    elif echo "$output" | grep -q "already up-to-date"; then
      log_pass "A record is already up-to-date (no change needed)"
    else
      log_fail "No record update detected"
      echo "    Output snippet:"
      echo "$output" | tail -20 | sed 's/^/      /'
    fi

    if echo "$output" | grep -q "AWS identity:"; then
      log_pass "AWS identity verified (validate() succeeded)"
    else
      log_fail "AWS identity check not found in logs"
    fi

    if echo "$output" | grep -q "Using AWS credentials from environment"; then
      log_pass "Auth via environment variables"
    elif echo "$output" | grep -q "Using AWS profile"; then
      log_pass "Auth via AWS profile"
    fi

    if echo "$output" | grep -q "Using default AWS profile"; then
      log_pass "Auth via default profile fallback"
    fi

    # Test 2: Missing credentials (expected failure)
    log_section "Test: Route53 missing credentials (expected failure)"

    fail_output=$(run_ddns "$compose_aws" 10 \
      -e "AWS_ACCESS_KEY_ID=" \
      -e "AWS_SECRET_ACCESS_KEY=" \
      -e "AWS_PROFILE=" \
      -e "SLEEP=2")

    if echo "$fail_output" | grep -q "No valid AWS credentials found"; then
      log_pass "Gracefully rejected missing credentials"
    else
      log_fail "Did not reject missing credentials as expected"
      echo "    Output: $(echo "$fail_output" | tail -3)"
    fi

    # Test 3: Unknown provider (expected failure)
    log_section "Test: Unknown provider (expected failure)"

    fail_output=$(run_ddns "$compose_aws" 10 \
      -e "DNS_PROVIDER=bind" \
      -e "SLEEP=2")

    if echo "$fail_output" | grep -q "Unknown DNS_PROVIDER"; then
      log_pass "Gracefully rejected unknown provider"
    else
      log_fail "Did not reject unknown provider as expected"
      echo "    Output: $(echo "$fail_output" | tail -3)"
    fi
  fi
fi

# ============================================================================
# Cloudflare Tests
# ============================================================================

compose_cf="${eth_docker_dir}/traefik-cf.yml"

if $test_cf; then
  echo -e "\n========================================"
  echo -e "  Cloudflare Provider Tests"
  echo -e "========================================"

  cf_can_run=true

  ZONE_ID="$(env_var CF_ZONE_ID)"

  if [[ -z "$ZONE_ID" || "$ZONE_ID" == *"example"* ]]; then
    log_fail "CF_ZONE_ID is not configured"
    cf_can_run=false
  else
    log_pass "CF_ZONE_ID is set (${ZONE_ID})"
  fi

  if ! has_real_value CF_DNS_API_TOKEN; then
    log_fail "CF_DNS_API_TOKEN is not set (or still default)"
    cf_can_run=false
  else
    log_pass "CF_DNS_API_TOKEN is set"
  fi

  if [[ ! -f "$compose_cf" ]]; then
    log_fail "traefik-cf.yml not found at ${compose_cf}"
    cf_can_run=false
  fi

  if ! $cf_can_run; then
    echo -e "\n${yellow}Cloudflare tests skipped — missing credentials or compose file.${nc}"
    echo "  Fill in the relevant variables in ${env_file} and re-run."
  else
    build_ddns "$compose_cf"

    # Test 1: Basic update cycle
    # Compose interpolates CF_ZONE_ID, CF_DNS_API_TOKEN, DDNS_HOST, DOMAIN, etc. from .env.
    # We only override test-specific vars.
    log_section "Test: Cloudflare basic update cycle"

    output=$(run_ddns "$compose_cf" 20 \
      -e "SLEEP=2" \
      -e "TTL=60" \
      -e "LOG_LEVEL=debug")

    if echo "$output" | grep -q "Updated A record"; then
      log_pass "A record was updated"
    elif echo "$output" | grep -q "already up-to-date"; then
      log_pass "A record is already up-to-date (no change needed)"
    else
      log_fail "No record update detected"
      echo "    Output snippet:"
      echo "$output" | tail -20 | sed 's/^/      /'
    fi

    if echo "$output" | grep -q "Cloudflare validation failed"; then
      log_fail "Cloudflare validation failed — check token permissions"
    else
      log_pass "Cloudflare validation passed"
    fi

    # Test 2: Invalid token (expected failure)
    log_section "Test: Cloudflare invalid token (expected failure)"

    fail_output=$(run_ddns "$compose_cf" 10 \
      -e "CF_DNS_API_TOKEN=invalid-token-should-fail" \
      -e "SLEEP=2")

    if echo "$fail_output" | grep -q "Cloudflare validation failed"; then
      log_pass "Gracefully rejected invalid token"
    else
      log_fail "Did not reject invalid token as expected"
      echo "    Output: $(echo "$fail_output" | tail -3)"
    fi
  fi
fi

echo -e "\n${green}All requested tests complete.${nc}"
