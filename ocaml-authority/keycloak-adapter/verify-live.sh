#!/usr/bin/env bash
# Checks the adapter's Keycloak integration against a live server built from this fork. A recording stand-in
# kernel keeps every request the adapter sends and answers "allow"; with REAL_KERNEL=<authority_kernel> it
# passes each request on to the real kernel instead.
#
#   1. the SPI option spelling --spi-policy--typed-authority--{kernel-path,evidence-dir} reaches the factory
#   2. config["ledger"] survives realm import, typed/generic create, typed update, typed/generic read, export
#   3. the request projected for the agent's own token and for an RFC 8693 delegated token
#   4. what happens to UMA pushed claims that are not List<String>
#
# Private Keycloak on KC_PORT (default 18080; management port +1000) under target/live; stops it on exit.
# The realm is ../examples/keycloak/realm-template.json unless REALM_TEMPLATE names another file.
# Requirements: bash, curl, jq, Maven (mvn, or set MVN), the fork's distribution (quarkus/dist/target/keycloak-*.tar.gz).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LIVE="$HERE/target/live"
KC_PORT="${KC_PORT:-18080}"
KC="http://localhost:$KC_PORT"
REALM=typed-authority-demo
REALM_TEMPLATE="${REALM_TEMPLATE:-$REPO/ocaml-authority/examples/keycloak/realm-template.json}"
TOKEN_URL="$KC/realms/$REALM/protocol/openid-connect/token"

(cd "$HERE" && "${MVN:-mvn}" -q -B -DskipTests package)
mkdir -p "$LIVE"
DIST="$(ls "$REPO"/quarkus/dist/target/keycloak-*.tar.gz | head -1)"
KEYCLOAK_HOME="$LIVE/$(basename "$DIST" .tar.gz)"
[ -d "$KEYCLOAK_HOME" ] || tar -xzf "$DIST" -C "$LIVE"
cp "$HERE"/target/typed-authority-keycloak-adapter-*.jar "$KEYCLOAK_HOME/providers/"
rm -rf "$LIVE/requests" "$LIVE/evidence" "$KEYCLOAK_HOME/data"

cat > "$LIVE/recording-kernel.sh" <<'EOF'
#!/bin/sh
[ "$1" = eval ] || exit 64
dir="$(dirname "$0")/requests"
mkdir -p "$dir"
request=$(cat)
id=$(printf '%s' "$request" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
printf '%s\n' "$request" > "$dir/$id.json"
if [ -n "$TYPED_AUTHORITY_REAL_KERNEL" ]; then
  printf '%s' "$request" | "$TYPED_AUTHORITY_REAL_KERNEL" eval
  exit $?
fi
printf '{"schema":"typed-authority/decision/v1","request_id":"%s","decision":"allow","authority":{"grant":"stand-in","chain":[],"anchor":"recording kernel"},"reasons":[]}\n' "$id"
EOF
chmod +x "$LIVE/recording-kernel.sh"

TYPED_AUTHORITY_REAL_KERNEL="${REAL_KERNEL:-}" KC_BOOTSTRAP_ADMIN_USERNAME=admin KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  "$KEYCLOAK_HOME/bin/kc.sh" start-dev --http-port="$KC_PORT" --http-management-port=$((KC_PORT + 1000)) \
  --features=token-exchange-delegation,parameterized-scopes,admin-fine-grained-authz:v2 \
  --spi-policy--typed-authority--kernel-path="$LIVE/recording-kernel.sh" \
  --spi-policy--typed-authority--evidence-dir="$LIVE/evidence" > "$LIVE/keycloak.log" 2>&1 &
KC_PID=$!
trap 'kill $KC_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 120); do curl -sf -o /dev/null "$KC/realms/master" && break; sleep 1; done

echo "== 1. SPI options"
grep -o 'typed-authority: kernel=.*' "$LIVE/keycloak.log"

ADMIN=$(curl -s -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin \
  "$KC/realms/master/protocol/openid-connect/token" | jq -r .access_token)
admin() { curl -s -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' "$@"; }
ledger_of() { admin "$1" | jq -r '.config.ledger'; }

echo "== 2. config[\"ledger\"] through the admin API"
LEDGER="$(jq -c . "$HERE/src/test/resources/roundtrip-ledger.json")"
jq --arg ledger "$LEDGER" '(.clients[] | select(.clientId == "document-service") | .authorizationSettings.policies[]
  | select(.name == "typed-authority-kernel") | .config.ledger) = $ledger' "$REALM_TEMPLATE" > "$LIVE/realm.json"
echo "realm import: HTTP $(admin -o /dev/null -w '%{http_code}' -X POST --data @"$LIVE/realm.json" "$KC/admin/realms")"
DS=$(admin "$KC/admin/realms/$REALM/clients?clientId=document-service" | jq -r '.[0].id')
BASE="$KC/admin/realms/$REALM/clients/$DS/authz/resource-server"
P=$(admin "$BASE/policy?name=typed-authority-kernel" | jq -r '.[0].id')
same() { [ "$1" = "$2" ] && echo same || echo DIFFERENT; }
echo "import  -> generic read: $(same "$(ledger_of "$BASE/policy/$P")" "$LEDGER")"
echo "import  -> typed read:   $(same "$(ledger_of "$BASE/policy/typed-authority/$P")" "$LEDGER")"
UPDATED='{"schema":"typed-authority/ledger/v1","updated":true}'
admin -o /dev/null -X PUT -d "$(admin "$BASE/policy/typed-authority/$P" | jq -c --arg l "$UPDATED" '.config.ledger = $l')" "$BASE/policy/typed-authority/$P"
echo "typed update -> read:    $(same "$(ledger_of "$BASE/policy/typed-authority/$P")" "$UPDATED")"
for via in typed generic; do
  path=$([ $via = typed ] && echo policy/typed-authority || echo policy)
  admin -o /dev/null -X POST -d "{\"name\":\"created-$via\",\"type\":\"typed-authority\",\"config\":{\"ledger\":\"{}\"}}" "$BASE/$path"
  id=$(admin "$BASE/policy?name=created-$via" | jq -r '.[0].id')
  echo "$via create -> read:  $(same "$(ledger_of "$BASE/policy/typed-authority/$id")" "{}")"
done
echo "partial export:          $(admin -X POST "$KC/admin/realms/$REALM/partial-export?exportClients=true" \
  | jq -c '[.clients[].authorizationSettings.policies[]? | select(.type == "typed-authority") | {name, ledger: .config.ledger}]')"
admin -o /dev/null -X PUT -d "$(admin "$BASE/policy/typed-authority/$P" | jq -c --arg l "$LEDGER" '.config.ledger = $l')" "$BASE/policy/typed-authority/$P"

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
ask() { # TOKEN CLAIMS_JSON -> response; the projected request is left in $LIVE/requests
  rm -rf "$LIVE/requests"
  curl -s -H "Authorization: Bearer $1" -d grant_type=urn:ietf:params:oauth:grant-type:uma-ticket -d audience=document-service \
    -d 'permission=q3-report#read' -d response_mode=decision -d claim_token_format=urn:ietf:params:oauth:token-type:jwt \
    -d "claim_token=$(printf '%s' "$2" | b64url)" "$TOKEN_URL"
}
projected() { if ls "$LIVE"/requests/*.json > /dev/null 2>&1; then jq -c "$1" "$LIVE"/requests/*.json; else echo "(kernel not called)"; fi; }
decided() { # the kernel's decision document (from evidence-dir) for the last request
  local id; id=$(jq -r .request_id "$LIVE"/requests/*.json 2> /dev/null) || { echo "-"; return; }
  jq -c '{decision, reasons: [.reasons[].code], grant: .authority.grant}' "$LIVE/evidence/$id.json"
}

echo "== 3. projection of live tokens"
AGENT=$(curl -s -u research-agent:research-agent-secret -d grant_type=client_credentials "$TOKEN_URL" | jq -r .access_token)
echo "agent token:     $(ask "$AGENT" '{"mandate":["generate-report"],"effect":["observe"]}')"
projected '{query, subject: .facts.subject, actor_chain: .facts.actor_chain, principals: .facts.principals, ledger: (.ledger | type)}'
echo "kernel decision: $(decided)"

AP=$(admin "$KC/admin/realms/$REALM/clients?clientId=admin-permissions" | jq -r '.[0].id')
AG=$(admin "$KC/admin/realms/$REALM/clients?clientId=research-agent" | jq -r '.[0].id')
admin -o /dev/null -X POST -d "{\"name\":\"actor-is-research-agent\",\"clients\":[\"$AG\"]}" "$KC/admin/realms/$REALM/clients/$AP/authz/resource-server/policy/client"
admin -o /dev/null -X POST -d '{"name":"research-agent-may-act-for-users","resourceType":"Users","scopes":["delegate"],"policies":["actor-is-research-agent"]}' \
  "$KC/admin/realms/$REALM/clients/$AP/authz/resource-server/permission/scope"
CJ="$LIVE/cookies.txt"; rm -f "$CJ"; REDIRECT=http://localhost:8765/callback
curl -s -c "$CJ" -b "$CJ" "$KC/realms/$REALM/protocol/openid-connect/auth?client_id=samantha-app&response_type=code&scope=openid%20delegation:client:research-agent&redirect_uri=$REDIRECT&state=v" > "$LIVE/login.html"
action=$(grep -o 'action="[^"]*"' "$LIVE/login.html" | head -1 | sed 's/action="//;s/"$//;s/&amp;/\&/g')
next=$(curl -s -c "$CJ" -b "$CJ" -o /dev/null -w '%{redirect_url}' --data-urlencode username=samantha --data-urlencode password=samantha "$action")
curl -s -c "$CJ" -b "$CJ" "$next" > "$LIVE/consent.html"
action=$(grep -o 'action="[^"]*consent[^"]*"' "$LIVE/consent.html" | sed 's/action="//;s/"$//;s/&amp;/\&/g')
form_code=$(grep -o 'name="code" value="[^"]*"' "$LIVE/consent.html" | sed 's/.*value="//;s/"$//')
callback=$(curl -s -c "$CJ" -b "$CJ" -o /dev/null -w '%{redirect_url}' --data-urlencode "code=$form_code" --data-urlencode accept=Yes "$KC$action")
auth_code=$(printf '%s' "$callback" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
SAMANTHA=$(curl -s -u samantha-app:samantha-app-secret -d grant_type=authorization_code -d "code=$auth_code" -d redirect_uri="$REDIRECT" "$TOKEN_URL" | jq -r .access_token)
DELEGATED=$(curl -s -u research-agent:research-agent-secret -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d "subject_token=$SAMANTHA" -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d "actor_token=$AGENT" -d actor_token_type=urn:ietf:params:oauth:token-type:access_token "$TOKEN_URL" | jq -r .access_token)
echo "delegated token claims: $(echo "$DELEGATED" | cut -d. -f2 | tr '_-' '/+' | awk '{ n = length($0) % 4; if (n) $0 = $0 substr("===", 1, 4 - n); print }' | base64 -d | jq -c '{sub, azp, act, realm_roles: .realm_access.roles}')"
echo "delegated token: $(ask "$DELEGATED" '{"mandate":["generate-report"],"effect":["observe"]}')"
projected '{subject: .facts.subject, actor_chain: .facts.actor_chain, principals: .facts.principals}'
echo "kernel decision: $(decided)"

echo "== 4. pushed claims that are not List<String>"
for claims in '{"mandate":"generate-report","effect":"observe"}' '{"mandate":["generate-report","publish-release"],"effect":[7]}' \
              '{}' '{"mandate":[null],"effect":[{"kind":"observe"}]}'; do
  printf '%-64s %s ' "$claims" "$(ask "$AGENT" "$claims")"
  projected '.query | {mandate: (if has("mandate") then .mandate else "(absent)" end), effect: (if has("effect") then .effect else "(absent)" end)}'
  printf '%64s kernel decision: %s\n' '' "$(decided)"
done
grep -m1 -A3 'ClassCastException' "$LIVE/keycloak.log" | grep -o 'ClassCastException: class [^ ]* cannot be cast to class [^ ]*\|at org.keycloak[^ ]*' || true
