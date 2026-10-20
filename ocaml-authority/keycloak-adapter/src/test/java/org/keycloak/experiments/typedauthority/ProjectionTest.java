package org.keycloak.experiments.typedauthority;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;
import org.keycloak.authorization.policy.evaluation.Evaluation;

class ProjectionTest {

    static final Clock FIXED = Clock.fixed(Instant.parse("2026-09-29T12:00:00.750Z"), ZoneOffset.UTC);
    static final String LEDGER = "{\"schema\":\"typed-authority/ledger/v1\",\"principals\":[],\"mandates\":[],\"grants\":[]}";

    final DemoRealm demo = new DemoRealm();
    final Projection projection = new Projection(FIXED);

    static final String SAMANTHA_FACTS = """
            { "type": "user", "id": "samantha",
              "realm_roles": ["default-roles-typed-authority-demo", "document-publisher", "offline_access",
                              "realm-operator", "report-author", "uma_authorization"],
              "client_roles": { "document-service": ["reader"] } }""";
    static final String RESEARCH_AGENT_FACTS = """
            { "type": "service", "id": "research-agent",
              "realm_roles": ["default-roles-typed-authority-demo", "offline_access", "uma_authorization"],
              "client_roles": { "document-service": ["reader"] } }""";
    static final String SUMMARY_AGENT_FACTS = """
            { "type": "service", "id": "summary-agent",
              "realm_roles": ["default-roles-typed-authority-demo", "offline_access", "uma_authorization"],
              "client_roles": {} }""";

    ObjectNode only(Evaluation evaluation) throws IOException {
        List<ObjectNode> requests = projection.requests(evaluation);
        assertEquals(1, requests.size());
        return requests.get(0);
    }

    static JsonNode json(String text) throws IOException {
        return Projection.JSON.readTree(text);
    }

    @Test
    void directIdentity() throws IOException {
        ObjectNode request = only(demo.request().identity(demo.samantha).scopes("generate")
                .pushed("mandate", List.of("generate-report")).pushed("effect", List.of("produce:organization"))
                .ledger(LEDGER).evaluation());

        UUID.fromString(request.remove("request_id").textValue());
        assertEquals(json("""
                { "schema": "typed-authority/request/v1",
                  "query": { "mandate": "generate-report",
                             "capability": { "resource_type": "document", "action": "generate" },
                             "resource": "q3-report",
                             "effect": { "kind": "produce", "audience": "organization" } },
                  "facts": { "source": "keycloak", "realm": "typed-authority-demo",
                             "evaluated_at": "2026-09-29T12:00:00Z",
                             "subject": { "type": "user", "id": "samantha" },
                             "actor_chain": [],
                             "principals": [ %s ] },
                  "ledger": %s }""".formatted(SAMANTHA_FACTS, LEDGER)), request);
    }

    @Test
    void delegatedIdentityWithTwoDeepActChain() throws IOException {
        // samantha -> research-agent -> summary-agent; the token's outermost act is the current actor.
        ObjectNode request = only(demo.request().identity(demo.samantha)
                .actors(demo.summaryAgentAccount, demo.researchAgentAccount).scopes("read").evaluation());

        assertEquals(json("{\"type\":\"user\",\"id\":\"samantha\"}"), request.at("/facts/subject"));
        assertEquals(json("[{\"type\":\"service\",\"id\":\"summary-agent\"},{\"type\":\"service\",\"id\":\"research-agent\"}]"),
                request.at("/facts/actor_chain"));
        assertEquals(json("[" + SAMANTHA_FACTS + "," + SUMMARY_AGENT_FACTS + "," + RESEARCH_AGENT_FACTS + "]"),
                request.at("/facts/principals"));
    }

    @Test
    void actClaimAsKeycloakDelegationWritesIt() throws IOException {
        // TokenExchangeDelegationProvider copies may_act (sub, client_id) and nests the actor token's own act.
        String act = "{\"sub\":\"u-sa-summary-agent\",\"client_id\":\"summary-agent\","
                + "\"act\":{\"sub\":\"u-sa-research-agent\",\"client_id\":\"research-agent\"}}";
        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read");
        request.identityAttributes.put("act", List.of(act));
        request.identityAttributes.put("jti", List.of(DemoRealm.DELEGATED_JTI));

        assertEquals(json("[{\"type\":\"service\",\"id\":\"summary-agent\"},{\"type\":\"service\",\"id\":\"research-agent\"}]"),
                only(request.evaluation()).at("/facts/actor_chain"));
    }

    @Test
    void serviceAccountResolvesToClientId() throws IOException {
        ObjectNode request = only(demo.request().identity(demo.researchAgentAccount).scopes("read").evaluation());

        assertEquals(json("{\"type\":\"service\",\"id\":\"research-agent\"}"), request.at("/facts/subject"));
        assertEquals(json("[" + RESEARCH_AGENT_FACTS + "]"), request.at("/facts/principals"));
    }

    @Test
    void resourceServerIdentityIdIsTheClientsInternalId() throws IOException {
        // KeycloakIdentity.getId() is the client id (not the user id) when a resource server uses its own token.
        demo.user("u-sa-document-service", "service-account-document-service", demo.documentService, List.of(), List.of());
        ObjectNode request = only(demo.request().identityId("c-document-service").scopes("read").evaluation());

        assertEquals(json("{\"type\":\"service\",\"id\":\"document-service\"}"), request.at("/facts/subject"));
    }

    @Test
    void unresolvableIdentityIsAnError() {
        assertThrows(IllegalStateException.class,
                () -> projection.requests(demo.request().identityId("no-such-user").scopes("read").evaluation()));
    }

    @Test
    void malformedActClaimIsAnError() {
        DemoRealm.Request noSub = demo.request().identity(demo.samantha).scopes("read");
        noSub.identityAttributes.put("act", List.of("{\"client_id\":\"research-agent\"}"));
        assertThrows(IllegalArgumentException.class, () -> projection.requests(noSub.evaluation()));

        DemoRealm.Request notJson = demo.request().identity(demo.samantha).scopes("read");
        notJson.identityAttributes.put("act", List.of("research-agent"));
        assertThrows(IOException.class, () -> projection.requests(notJson.evaluation()));
    }

    @Test
    void missingMandateAndEffectAreOmitted() throws IOException {
        JsonNode query = only(demo.request().identity(demo.samantha).scopes("read").evaluation()).get("query");
        assertFalse(query.has("mandate"));
        assertFalse(query.has("effect"));

        JsonNode emptyLists = only(demo.request().identity(demo.samantha).scopes("read")
                .pushed("mandate", List.of()).pushed("effect", List.of()).evaluation()).get("query");
        assertFalse(emptyLists.has("mandate"));
        assertFalse(emptyLists.has("effect"));
    }

    @Test
    void multiValuedClaimsAreForwardedAsArrays() throws IOException {
        JsonNode query = only(demo.request().identity(demo.samantha).scopes("read")
                .pushed("mandate", List.of("generate-report", "publish-release"))
                .pushed("effect", List.of("observe", "disclose:public")).evaluation()).get("query");

        assertEquals(json("[\"generate-report\",\"publish-release\"]"), query.get("mandate"));
        assertEquals(json("[{\"kind\":\"observe\"},{\"kind\":\"disclose\",\"audience\":\"public\"}]"), query.get("effect"));
    }

    @Test
    void effectStringsAreSplitAtTheFirstColonWithoutValidation() throws IOException {
        String[][] cases = {
            {"observe", "{\"kind\":\"observe\"}"},
            {"administer", "{\"kind\":\"administer\"}"},
            {"produce:organization", "{\"kind\":\"produce\",\"audience\":\"organization\"}"},
            {"disclose:public", "{\"kind\":\"disclose\",\"audience\":\"public\"}"},
            {"produce:", "{\"kind\":\"produce\",\"audience\":\"\"}"},
            {"disclose:org:eu", "{\"kind\":\"disclose\",\"audience\":\"org:eu\"}"},
            {"observe:self", "{\"kind\":\"observe\",\"audience\":\"self\"}"},
            {"efect", "{\"kind\":\"efect\"}"},
            {"", "{\"kind\":\"\"}"},
        };
        for (String[] c : cases) {
            JsonNode effect = only(demo.request().identity(demo.samantha).scopes("read")
                    .pushed("effect", List.of(c[0])).evaluation()).at("/query/effect");
            assertEquals(json(c[1]), effect, c[0]);
        }
    }

    @Test
    void pushedClaimsThatAreNotListsOfStringsAreForwardedAsJson() throws IOException {
        // claim_token {"mandate":"generate-report","effect":[7]} passes AuthorizationTokenService's unchecked cast.
        JsonNode query = only(demo.request().identity(demo.samantha).scopes("read")
                .pushed("mandate", "generate-report").pushed("effect", List.of(7)).evaluation()).get("query");

        assertEquals(json("\"generate-report\""), query.get("mandate"));
        assertEquals(json("7"), query.get("effect"));

        // {"mandate":[null],"effect":["observe",null,{"kind":"observe"}]}
        JsonNode nulls = only(demo.request().identity(demo.samantha).scopes("read")
                .pushed("mandate", Arrays.asList((Object) null))
                .pushed("effect", Arrays.asList("observe", null, Map.of("kind", "observe"))).evaluation()).get("query");

        assertEquals(json("null"), nulls.get("mandate"));
        assertEquals(json("[{\"kind\":\"observe\"},null,{\"kind\":\"observe\"}]"), nulls.get("effect"));
    }

    @Test
    void ledgerIsEmbeddedAsJsonTree() throws IOException {
        JsonNode ledger = only(demo.request().identity(demo.samantha).scopes("read").ledger(LEDGER).evaluation()).get("ledger");
        assertTrue(ledger.isObject());
        assertEquals(json(LEDGER), ledger);
    }

    @Test
    void ledgerThatIsNotStrictJsonIsEmbeddedAsString() throws IOException {
        String duplicateKeys = "{\"schema\":\"typed-authority/ledger/v1\",\"grants\":[],\"grants\":[{\"id\":\"g-injected\"}]}";
        for (String text : List.of(duplicateKeys, "{\"schema\":", "{} {}", "", "   ")) {
            JsonNode ledger = only(demo.request().identity(demo.samantha).scopes("read").ledger(text).evaluation()).get("ledger");
            assertTrue(ledger.isTextual(), text);
            assertEquals(text, ledger.textValue());
        }
    }

    @Test
    void absentLedgerIsNull() throws IOException {
        assertTrue(only(demo.request().identity(demo.samantha).scopes("read").evaluation()).get("ledger").isNull());
    }

    @Test
    void oneRequestPerScopeWithDistinctIds() throws IOException {
        List<ObjectNode> requests = projection.requests(demo.request().identity(demo.samantha).scopes("read", "generate").evaluation());

        assertEquals(2, requests.size());
        assertEquals("read", requests.get(0).at("/query/capability/action").textValue());
        assertEquals("generate", requests.get(1).at("/query/capability/action").textValue());
        assertFalse(requests.get(0).get("request_id").equals(requests.get(1).get("request_id")));
    }

    @Test
    void permissionWithoutResourceProjectsNulls() throws IOException {
        JsonNode query = only(demo.request().identity(demo.samantha).resource(null).scopes("read").evaluation()).get("query");
        assertTrue(query.at("/capability/resource_type").isNull());
        assertTrue(query.get("resource").isNull());
    }
}
