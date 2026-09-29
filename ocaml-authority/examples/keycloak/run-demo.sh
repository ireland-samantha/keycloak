#!/usr/bin/env bash
# End-to-end demonstration: Keycloak (this fork) -> Java adapter -> OCaml kernel.
#
# Every scenario is sent three times with the same token, the same resource and
# the same pushed claims, to three resource servers in the same realm:
#   document-service-rbac       conventional role policies, roles read from the token (Keycloak's default)
#   document-service-rbac-live  the same role policies with fetchRoles=true (live role mappings)
#   document-service            one "typed-authority" policy backed by the OCaml kernel
#
# Requirements: bash, curl, jq, a JDK, Maven, dune; a built Keycloak distribution
# of this fork (./mvnw -pl quarkus/deployment,quarkus/dist -am -DskipTests install).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"              # ocaml-authority/
REPO="$(cd "$ROOT/.." && pwd)"                 # the Keycloak fork
WORK="${WORK:-$ROOT/_demo}"
KC_PORT="${KC_PORT:-8080}"
KC="http://localhost:$KC_PORT"
REALM=typed-authority-demo
TOKEN_URL="$KC/realms/$REALM/protocol/openid-connect/token"
EVIDENCE="$WORK/evidence"
OUT="${OUT:-$HERE/demo-output}"

log() { printf '\n== %s\n' "$*"; }
jwt_payload() { cut -d. -f2 | tr '_-' '/+' | awk '{ n = length($0) % 4; if (n) $0 = $0 substr("===", 1, 4 - n); print }' | base64 -d; }

# ---------------------------------------------------------------- build
log "building the OCaml kernel and the Java adapter"
(cd "$ROOT" && dune build ./bin/authority_kernel/main.exe)
KERNEL="$ROOT/_build/default/bin/authority_kernel/main.exe"
(cd "$ROOT/keycloak-adapter" && mvn -q -B -DskipTests package)
ADAPTER_JAR="$(ls "$ROOT"/keycloak-adapter/target/typed-authority-keycloak-adapter-*.jar | grep -v -e sources -e tests | head -1)"

# ---------------------------------------------------------------- keycloak
mkdir -p "$WORK" "$EVIDENCE" "$OUT"
rm -f "$EVIDENCE"/*.json
if [ -z "${KEYCLOAK_HOME:-}" ]; then
  DIST="$(ls "$REPO"/quarkus/dist/target/keycloak-*.tar.gz | head -1)"
  KEYCLOAK_HOME="$WORK/$(basename "$DIST" .tar.gz)"
  [ -d "$KEYCLOAK_HOME" ] || tar -xzf "$DIST" -C "$WORK"
fi
cp "$ADAPTER_JAR" "$KEYCLOAK_HOME/providers/"

log "starting Keycloak $(basename "$KEYCLOAK_HOME") with the typed-authority provider"
KC_BOOTSTRAP_ADMIN_USERNAME=admin KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  "$KEYCLOAK_HOME/bin/kc.sh" start-dev --http-port="$KC_PORT" \
  --features=token-exchange-delegation,parameterized-scopes,admin-fine-grained-authz:v2 \
  --spi-policy--typed-authority--kernel-path="$KERNEL" \
  --spi-policy--typed-authority--evidence-dir="$EVIDENCE" \
  > "$WORK/keycloak.log" 2>&1 &
KC_PID=$!
trap 'kill $KC_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 120); do
  curl -sf -o /dev/null "$KC/realms/master" && break
  sleep 1
done
curl -sf -o /dev/null "$KC/realms/master" || { echo "Keycloak did not start; see $WORK/keycloak.log"; exit 1; }

ADMIN=$(curl -s -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin \
  "$KC/realms/master/protocol/openid-connect/token" | jq -r .access_token)
admin() { curl -s -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' "$@"; }

# ---------------------------------------------------------------- realm
# The committed ledger is written for a fixed evaluation time (2026-09-29).
# Shift its validity windows so the live demo means the same thing on any date:
# windows that had ended by the fixture time end 90 days ago, all others end in 90 days.
log "importing realm $REALM with the kernel ledger in the policy config"
FIXTURE_TIME="$(jq -r '.defaults.facts.evaluated_at' "$ROOT/examples/scenarios/demo.json")"
LEDGER="$(jq --arg t "$FIXTURE_TIME" '
  def shift: if . == null then null elif . < $t then (now - 90*86400 | todate) else (now + 90*86400 | todate) end;
  .ledger
  | .grants |= map(if has("valid_until") then .valid_until |= shift else . end
                  | if has("valid_from") then .valid_from |= (if . <= $t then (now - 180*86400 | todate) else shift end) else . end)
' "$ROOT/examples/scenarios/demo.json")"
admin -X DELETE "$KC/admin/realms/$REALM" -o /dev/null || true
jq --arg ledger "$LEDGER" '
  (.clients[] | select(.clientId == "document-service") | .authorizationSettings.policies[]
   | select(.name == "typed-authority-kernel") | .config.ledger) = $ledger
' "$HERE/realm-template.json" > "$WORK/realm.json"
code=$(admin -o /dev/null -w '%{http_code}' -X POST --data @"$WORK/realm.json" "$KC/admin/realms")
[ "$code" = 201 ] || { echo "realm import failed: HTTP $code"; exit 1; }

# FGAP v2: research-agent may act on behalf of users (required for delegation:client).
AP=$(admin "$KC/admin/realms/$REALM/clients?clientId=admin-permissions" | jq -r '.[0].id')
AG=$(admin "$KC/admin/realms/$REALM/clients?clientId=research-agent" | jq -r '.[0].id')
admin -o /dev/null -X POST -d "{\"name\":\"actor-is-research-agent\",\"clients\":[\"$AG\"]}" \
  "$KC/admin/realms/$REALM/clients/$AP/authz/resource-server/policy/client"
admin -o /dev/null -X POST -d '{"name":"research-agent-may-act-for-users","resourceType":"Users","scopes":["delegate"],"policies":["actor-is-research-agent"]}' \
  "$KC/admin/realms/$REALM/clients/$AP/authz/resource-server/permission/scope"

# ---------------------------------------------------------------- tokens
log "samantha logs in to samantha-app and consents to delegation:client:research-agent"
CJ="$WORK/cookies.txt"; rm -f "$CJ"
REDIRECT=http://localhost:8765/callback
curl -s -c "$CJ" -b "$CJ" \
  "$KC/realms/$REALM/protocol/openid-connect/auth?client_id=samantha-app&response_type=code&scope=openid%20delegation:client:research-agent&redirect_uri=$REDIRECT&state=demo" \
  > "$WORK/login.html"
action=$(grep -o 'action="[^"]*"' "$WORK/login.html" | head -1 | sed 's/action="//;s/"$//;s/&amp;/\&/g')
next=$(curl -s -c "$CJ" -b "$CJ" -o /dev/null -w '%{redirect_url}' \
  --data-urlencode username=samantha --data-urlencode password=samantha "$action")
curl -s -c "$CJ" -b "$CJ" "$next" > "$WORK/consent.html"
grep -q 'research-agent to act on your behalf' "$WORK/consent.html" || { echo "no delegation consent screen"; exit 1; }
action=$(grep -o 'action="[^"]*consent[^"]*"' "$WORK/consent.html" | sed 's/action="//;s/"$//;s/&amp;/\&/g')
form_code=$(grep -o 'name="code" value="[^"]*"' "$WORK/consent.html" | sed 's/.*value="//;s/"$//')
callback=$(curl -s -c "$CJ" -b "$CJ" -o /dev/null -w '%{redirect_url}' \
  --data-urlencode "code=$form_code" --data-urlencode accept=Yes "$KC$action")
auth_code=$(printf '%s' "$callback" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
SAMANTHA=$(curl -s -d grant_type=authorization_code -d client_id=samantha-app -d "code=$auth_code" \
  -d redirect_uri="$REDIRECT" "$TOKEN_URL" | jq -r .access_token)

log "research-agent obtains its own token (client credentials)"
AGENT=$(curl -s -u research-agent:research-agent-secret -d grant_type=client_credentials "$TOKEN_URL" | jq -r .access_token)

log "research-agent exchanges samantha's token for a delegated token (RFC 8693, actor_token)"
DELEGATED=$(curl -s -u research-agent:research-agent-secret \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d "subject_token=$SAMANTHA" -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d "actor_token=$AGENT" -d actor_token_type=urn:ietf:params:oauth:token-type:access_token \
  "$TOKEN_URL" | jq -r .access_token)
echo "$DELEGATED" | jwt_payload | jq '{sub, azp, act, realm_roles: .realm_access.roles}' | tee "$OUT/delegated-token-claims.json"

# ---------------------------------------------------------------- scenarios
# ask TOKEN AUDIENCE PERMISSION MANDATE EFFECT -> prints true / false / error text
ask() {
  local claims
  claims=$(jq -cn --arg m "$4" --arg e "$5" '{mandate: [$m], effect: [$e]}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
  curl -s -H "Authorization: Bearer $1" \
    -d grant_type=urn:ietf:params:oauth:grant-type:uma-ticket -d "audience=$2" -d "permission=$3" \
    -d response_mode=decision -d claim_token_format=urn:ietf:params:oauth:token-type:jwt -d "claim_token=$claims" \
    "$TOKEN_URL" | jq -r 'if has("result") then (.result | tostring) else (.error // "error") end'
}

RESULTS="$OUT/results.md"
printf '| scenario | token | permission | mandate | effect | RBAC (token roles) | RBAC (live roles) | kernel via Keycloak | kernel decision | reason codes |\n|---|---|---|---|---|---|---|---|---|---|\n' > "$RESULTS"

run() { # NAME TOKEN_LABEL TOKEN PERMISSION MANDATE EFFECT
  local name=$1 label=$2 token=$3 perm=$4 mandate=$5 effect=$6 rbac live kernel ev decision codes
  rbac=$(ask "$token" document-service-rbac "$perm" "$mandate" "$effect")
  live=$(ask "$token" document-service-rbac-live "$perm" "$mandate" "$effect")
  kernel=$(ask "$token" document-service "$perm" "$mandate" "$effect")
  ev=$(ls -t "$EVIDENCE"/*.json 2>/dev/null | head -1 || true)
  if [ -n "$ev" ]; then
    cp "$ev" "$OUT/$name.decision.json"
    decision=$(jq -r .decision "$ev"); codes=$(jq -r '[.reasons[].code] | join(", ")' "$ev")
    rm -f "$EVIDENCE"/*.json
  else
    decision="(no evidence)"; codes=""
  fi
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$name" "$label" "$perm" "$mandate" "$effect" "$rbac" "$live" "$kernel" "$decision" "$codes" >> "$RESULTS"
  printf '%-36s rbac=%-5s rbac-live=%-5s kernel=%-5s %s %s\n' "$name" "$rbac" "$live" "$kernel" "$decision" "$codes"
}

log "scenarios"
run 01-direct-read                agent     "$AGENT"     "q3-report#read"          generate-report observe
run 02-delegated-generate         delegated "$DELEGATED" "q3-report#generate"      generate-report produce:organization
run 03-capability-denied          agent     "$AGENT"     "realm-config#administer" operate-realm   administer
run 04-wrong-effect               delegated "$DELEGATED" "q3-report#generate"      generate-report produce:public
run 05-expired-delegation         delegated "$DELEGATED" "q3-report#read"          generate-report observe
run 06-missing-provenance         agent     "$AGENT"     "q3-report#publish"       publish-release disclose:public
run 07-mandate-capability-mismatch delegated "$DELEGATED" "q3-report#publish"      generate-report disclose:public
run 08-agent-administers-for-samantha delegated "$DELEGATED" "realm-config#administer" generate-report administer

log "stale grant: remove samantha's report-author role, reuse the SAME delegated token"
SAM_ID=$(admin "$KC/admin/realms/$REALM/users?username=samantha&exact=true" | jq -r '.[0].id')
ROLE=$(admin "$KC/admin/realms/$REALM/roles/report-author")
admin -o /dev/null -X DELETE -d "[$ROLE]" "$KC/admin/realms/$REALM/users/$SAM_ID/role-mappings/realm"
run 09-anchor-role-removed        delegated "$DELEGATED" "q3-report#generate"      generate-report produce:organization
admin -o /dev/null -X POST -d "[$ROLE]" "$KC/admin/realms/$REALM/users/$SAM_ID/role-mappings/realm"
run 10-anchor-role-restored       delegated "$DELEGATED" "q3-report#generate"      generate-report produce:organization

log "results ($RESULTS)"
cat "$RESULTS"
{
  echo "keycloak: $(basename "$KEYCLOAK_HOME") built from $(git -C "$REPO" rev-parse HEAD)"
  echo "kernel:   $KERNEL"
  echo "adapter:  $(basename "$ADAPTER_JAR")"
  echo "date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/environment.txt"
