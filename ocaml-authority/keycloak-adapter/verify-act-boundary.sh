#!/usr/bin/env bash
# Adversarial check of where the "act" claim the adapter projects can come from, against a live Keycloak built
# from this fork. Each case prints the token's act/jti/sid, the actor chain the adapter projected (or that it
# refused), and the kernel's decision.
#
#   1. a genuine RFC 8693 delegated token (token exchange with samantha's consent)          -> actor chain
#   2. samantha's ordinary login token for samantha-app, carrying "act" from a hardcoded-claim protocol mapper
#      (JSON type), which Keycloak's delegation exchange never produced
#   3. the same with the mapper's JSON type set to String (KeycloakIdentity flattens both to one JSON text)
#   4. an admin-impersonation token (a realm user "helpdesk" with realm-management/impersonation impersonates
#      samantha): TokenManager.setActClaimFromImpersonator writes act = {sub, preferred_username}
#   5. a genuine delegated token whose actor_token (research-agent's client-credentials token) carries "act" from
#      a hardcoded mapper: TokenExchangeDelegationProvider nests the actor token's act verbatim
#
# ADAPTER_JAR=<jar> runs an existing adapter jar (e.g. one built before a change); by default the adapter is built.
# REAL_KERNEL=<authority_kernel> is required: every request is recorded and then decided by the real kernel.
# Private Keycloak on KC_PORT (default 18380; management port +1000) under target/live-boundary; stops it on exit.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LIVE="$HERE/target/live-boundary"
KC_PORT="${KC_PORT:-18380}"
KC="http://localhost:$KC_PORT"
REALM=typed-authority-demo
TOKEN_URL="$KC/realms/$REALM/protocol/openid-connect/token"
REDIRECT=http://localhost:8765/callback
: "${REAL_KERNEL:?set REAL_KERNEL to the authority_kernel executable}"

if [ -z "${ADAPTER_JAR:-}" ]; then
  (cd "$HERE" && "${MVN:-mvn}" -q -B -DskipTests package)
  ADAPTER_JAR="$(ls "$HERE"/target/typed-authority-keycloak-adapter-*.jar | head -1)"
fi
mkdir -p "$LIVE"
DIST="$(ls "$REPO"/quarkus/dist/target/keycloak-*.tar.gz | head -1)"
KEYCLOAK_HOME="$LIVE/$(basename "$DIST" .tar.gz)"
[ -d "$KEYCLOAK_HOME" ] || tar -xzf "$DIST" -C "$LIVE"
rm -f "$KEYCLOAK_HOME"/providers/typed-authority-keycloak-adapter-*.jar
cp "$ADAPTER_JAR" "$KEYCLOAK_HOME/providers/typed-authority-keycloak-adapter-under-test.jar"
rm -rf "$LIVE/requests" "$LIVE/evidence" "$KEYCLOAK_HOME/data"
echo "adapter jar: $ADAPTER_JAR ($(unzip -p "$ADAPTER_JAR" org/keycloak/experiments/typedauthority/Projection.class | grep -c jti || true) jti references)"

cat > "$LIVE/recording-kernel.sh" <<'EOF'
#!/bin/sh
[ "$1" = eval ] || exit 64
dir="$(dirname "$0")/requests"
mkdir -p "$dir"
request=$(cat)
id=$(printf '%s' "$request" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
printf '%s\n' "$request" > "$dir/$id.json"
printf '%s' "$request" | "$TYPED_AUTHORITY_REAL_KERNEL" eval
EOF
chmod +x "$LIVE/recording-kernel.sh"

TYPED_AUTHORITY_REAL_KERNEL="$REAL_KERNEL" KC_BOOTSTRAP_ADMIN_USERNAME=admin KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  "$KEYCLOAK_HOME/bin/kc.sh" start-dev --http-port="$KC_PORT" --http-management-port=$((KC_PORT + 1000)) \
  --features=token-exchange-delegation,parameterized-scopes,admin-fine-grained-authz:v2 \
  --spi-policy--typed-authority--kernel-path="$LIVE/recording-kernel.sh" \
  --spi-policy--typed-authority--evidence-dir="$LIVE/evidence" > "$LIVE/keycloak.log" 2>&1 &
KC_PID=$!
trap 'kill $KC_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 180); do curl -sf -o /dev/null "$KC/realms/master" && break; sleep 1; done

ADMIN=$(curl -s -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin \
  "$KC/realms/master/protocol/openid-connect/token" | jq -r .access_token)
admin() { curl -s -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' "$@"; }

# The realm, with the round-trip ledger; its delegation d-agent-read-for-samantha is made current (as the S5 test does).
LEDGER="$(jq -c '(.grants[] | select(.id == "d-agent-read-for-samantha") | .valid_until) = "2026-12-31T23:59:59Z"' \
  "$HERE/src/test/resources/roundtrip-ledger.json")"
jq --arg ledger "$LEDGER" '(.clients[] | select(.clientId == "document-service") | .authorizationSettings.policies[]
  | select(.name == "typed-authority-kernel") | .config.ledger) = $ledger' "$REPO/ocaml-authority/examples/keycloak/realm-template.json" > "$LIVE/realm.json"
echo "realm import: HTTP $(admin -o /dev/null -w '%{http_code}' -X POST --data @"$LIVE/realm.json" "$KC/admin/realms")"
R="$KC/admin/realms/$REALM"
client_uuid() { admin "$R/clients?clientId=$1" | jq -r '.[0].id'; }
SAPP=$(client_uuid samantha-app); AG=$(client_uuid research-agent); DSR=$(client_uuid document-service-rbac); AP=$(client_uuid admin-permissions)
AG_SA=$(admin "$R/clients/$AG/service-account-user" | jq -r .id)
DSR_SA=$(admin "$R/clients/$DSR/service-account-user" | jq -r .id)
SAM=$(admin "$R/users?username=samantha&exact=true" | jq -r '.[0].id')

# research-agent may act for users (FGAP v2), as in verify-live.sh.
admin -o /dev/null -X POST -d "{\"name\":\"actor-is-research-agent\",\"clients\":[\"$AG\"]}" "$KC/admin/realms/$REALM/clients/$AP/authz/resource-server/policy/client"
admin -o /dev/null -X POST -d '{"name":"research-agent-may-act-for-users","resourceType":"Users","scopes":["delegate"],"policies":["actor-is-research-agent"]}' \
  "$KC/admin/realms/$REALM/clients/$AP/authz/resource-server/permission/scope"

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
claims_of() { cut -d. -f2 | tr '_-' '/+' | awk '{ n = length($0) % 4; if (n) $0 = $0 substr("===", 1, 4 - n); print }' | base64 -d; }
ask() { # TOKEN -> UMA decision response; the projected request is left in $LIVE/requests
  rm -rf "$LIVE/requests"
  curl -s -H "Authorization: Bearer $1" -d grant_type=urn:ietf:params:oauth:grant-type:uma-ticket -d audience=document-service \
    -d 'permission=q3-report#read' -d response_mode=decision -d claim_token_format=urn:ietf:params:oauth:token-type:jwt \
    -d "claim_token=$(printf '%s' '{"mandate":["generate-report"],"effect":["observe"]}' | b64url)" "$TOKEN_URL"
}
report() { # LABEL TOKEN
  echo "-- $1"
  echo "   token:     $(printf '%s' "$2" | claims_of | jq -c '{sub, azp, jti, sid, act}')"
  echo "   response:  $(ask "$2")"
  if ls "$LIVE"/requests/*.json > /dev/null 2>&1; then
    echo "   projected: $(jq -c '{subject: .facts.subject.id, actor_chain: [.facts.actor_chain[].id]}' "$LIVE"/requests/*.json)"
    local id; id=$(jq -r .request_id "$LIVE"/requests/*.json)
    echo "   kernel:    $(jq -c '{decision, reasons: [.reasons[].code] | unique, grant: .authority.grant, chain: [.authority.chain[]?.holder.id]}' "$LIVE/evidence/$id.json")"
  else
    echo "   projected: (kernel not called) $(grep -o 'Illegal[A-Za-z]*Exception: .*' "$LIVE/keycloak.log" | tail -1 | cut -c1-240)"
  fi
}

authcode() { # COOKIEJAR SCOPE USERNAME PASSWORD -> authorization code for samantha-app (logs in and consents as needed)
  local cj=$1 url="$KC/realms/$REALM/protocol/openid-connect/auth?client_id=samantha-app&response_type=code&scope=$2&redirect_uri=$REDIRECT&state=v"
  local page="$LIVE/page.html" next action form_code
  next=$(curl -s -c "$cj" -b "$cj" -o "$page" -w '%{redirect_url}' "$url")
  for _ in 1 2 3 4 5 6; do
    case "$next" in "$REDIRECT"*) printf '%s' "$next" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p'; return;; esac
    if [ -n "$next" ]; then next=$(curl -s -c "$cj" -b "$cj" -o "$page" -w '%{redirect_url}' "$next"); continue; fi
    if grep -q 'name="password"' "$page"; then
      action=$(grep -o 'action="[^"]*"' "$page" | head -1 | sed 's/action="//;s/"$//;s/&amp;/\&/g')
      next=$(curl -s -c "$cj" -b "$cj" -o "$page" -w '%{redirect_url}' --data-urlencode "username=$3" --data-urlencode "password=$4" "$action")
    elif grep -q 'consent' "$page"; then
      action=$(grep -o 'action="[^"]*consent[^"]*"' "$page" | sed 's/action="//;s/"$//;s/&amp;/\&/g')
      form_code=$(grep -o 'name="code" value="[^"]*"' "$page" | sed 's/.*value="//;s/"$//')
      next=$(curl -s -c "$cj" -b "$cj" -o "$page" -w '%{redirect_url}' --data-urlencode "code=$form_code" --data-urlencode accept=Yes "$KC$action")
    else
      echo "authcode: unexpected page" >&2; return 1
    fi
  done
}
samantha_app_token() { # CODE
  curl -s -u samantha-app:samantha-app-secret -d grant_type=authorization_code -d "code=$1" -d redirect_uri="$REDIRECT" "$TOKEN_URL" | jq -r .access_token
}
agent_token() { curl -s -u research-agent:research-agent-secret -d grant_type=client_credentials "$TOKEN_URL" | jq -r .access_token; }
delegate() { # SAMANTHA_TOKEN ACTOR_TOKEN
  curl -s -u research-agent:research-agent-secret -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d "subject_token=$1" -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    -d "actor_token=$2" -d actor_token_type=urn:ietf:params:oauth:token-type:access_token "$TOKEN_URL" | jq -r .access_token
}
hardcoded_act() { # NAME JSON_TYPE VALUE
  jq -nc --arg name "$1" --arg type "$2" --arg value "$3" '{name: $name, protocol: "openid-connect", protocolMapper: "oidc-hardcoded-claim-mapper",
    config: {"claim.name": "act", "claim.value": $value, "jsonType.label": $type, "access.token.claim": "true",
             "id.token.claim": "false", "userinfo.token.claim": "false", "introspection.token.claim": "true"}}'
}

echo "== 1. genuine delegated token"
CJ="$LIVE/cookies-1.txt"; rm -f "$CJ"
SAMANTHA_MAY_ACT=$(samantha_app_token "$(authcode "$CJ" 'openid%20delegation:client:research-agent' samantha samantha)")
report "delegated (token exchange, samantha consented)" "$(delegate "$SAMANTHA_MAY_ACT" "$(agent_token)")"

echo "== 2. act from a hardcoded-claim mapper (JSON) on samantha-app"
FORGED="{\"sub\":\"$AG_SA\",\"client_id\":\"research-agent\"}"
echo "   mapper: HTTP $(admin -o /dev/null -w '%{http_code}' -X POST -d "$(hardcoded_act forged-act JSON "$FORGED")" "$R/clients/$SAPP/protocol-mappers/models")"
CJ="$LIVE/cookies-2.txt"; rm -f "$CJ"
report "samantha's login token for samantha-app (no exchange, no delegation consent)" "$(samantha_app_token "$(authcode "$CJ" openid samantha samantha)")"

echo "== 3. the same mapper with JSON type String"
MID=$(admin "$R/clients/$SAPP/protocol-mappers/models" | jq -r '.[] | select(.name == "forged-act") | .id')
admin -o /dev/null -X PUT -d "$(hardcoded_act forged-act String "$FORGED" | jq -c --arg id "$MID" '. + {id: $id}')" "$R/clients/$SAPP/protocol-mappers/models/$MID"
CJ="$LIVE/cookies-3.txt"; rm -f "$CJ"
report "samantha's login token, act as a JSON string" "$(samantha_app_token "$(authcode "$CJ" openid samantha samantha)")"
admin -o /dev/null -X DELETE "$R/clients/$SAPP/protocol-mappers/models/$MID"

echo "== 4. admin impersonation"
admin -o /dev/null -X POST -d '{"username":"helpdesk","enabled":true,"email":"helpdesk@example.org","firstName":"Help","lastName":"Desk","credentials":[{"type":"password","value":"helpdesk","temporary":false}]}' "$R/users"
HD=$(admin "$R/users?username=helpdesk&exact=true" | jq -r '.[0].id')
RM=$(client_uuid realm-management)
admin -o /dev/null -X POST -d "[$(admin "$R/clients/$RM/roles/impersonation")]" "$R/users/$HD/role-mappings/clients/$RM"
HELPDESK=$(curl -s -d grant_type=password -d client_id=admin-cli -d username=helpdesk -d password=helpdesk "$TOKEN_URL" | jq -r .access_token)
CJ="$LIVE/cookies-4.txt"; rm -f "$CJ"
echo "   impersonate: $(curl -s -c "$CJ" -H "Authorization: Bearer $HELPDESK" -X POST "$R/users/$SAM/impersonation")"
# wrong credentials on purpose: if the impersonation session were not used, this login would fail instead of
# silently producing samantha's own token
report "helpdesk impersonating samantha, token for samantha-app" "$(samantha_app_token "$(authcode "$CJ" openid nobody nobody)")"

echo "== 5. act from a hardcoded-claim mapper on research-agent, nested by the delegation exchange"
echo "   mapper: HTTP $(admin -o /dev/null -w '%{http_code}' -X POST -d "$(hardcoded_act forged-inner-act JSON "{\"sub\":\"$DSR_SA\"}")" "$R/clients/$AG/protocol-mappers/models")"
AGENT_WITH_ACT=$(agent_token)
echo "   actor token: $(printf '%s' "$AGENT_WITH_ACT" | claims_of | jq -c '{sub, azp, jti, act}')"
CJ="$LIVE/cookies-5.txt"; rm -f "$CJ"
SAMANTHA_MAY_ACT=$(samantha_app_token "$(authcode "$CJ" 'openid%20delegation:client:research-agent' samantha samantha)")
report "delegated token whose actor token carried a mapper-made act" "$(delegate "$SAMANTHA_MAY_ACT" "$AGENT_WITH_ACT")"
