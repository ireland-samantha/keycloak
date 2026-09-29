package org.keycloak.experiments.typedauthority;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Stream;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;
import org.keycloak.authorization.permission.ResourcePermission;
import org.keycloak.authorization.policy.evaluation.Evaluation;

/**
 * Adversarial review of the adapter's side of the trust boundary: where the "act" identity attribute comes from,
 * what UMA pushed claims can look like when they reach the policy, how strictly the kernel's answer is read, and
 * whether anything the kernel says reaches the requesting client. Tests named known_weakness_* pin behaviour that
 * is undesired but cannot be fixed inside the adapter without changing the design; see the finding ids.
 */
class BoundaryAttackTest {

    final DemoRealm demo = new DemoRealm();
    final Projection projection = new Projection(ProjectionTest.FIXED);

    // ---------------------------------------------------------------------------------------------------------
    // Where "act" comes from. TokenExchangeDelegationProvider always issues the delegated token on a new TRANSIENT
    // user session through the token-exchange grant, so its jti starts with "tr" (session type), "rt" or "lt"
    // (regular or lightweight token), "te" (grant type) and ':' (DefaultTokenContextEncoderProvider). Captured from
    // a live delegated token of this fork: jti "trrtte:45dfa700-...", no sid, act {sub, client_id}.
    // ---------------------------------------------------------------------------------------------------------

    static final String DELEGATED_JTI = DemoRealm.DELEGATED_JTI;
    static final String AGENT_ACT = "{\"sub\":\"u-sa-research-agent\",\"client_id\":\"research-agent\"}";

    DemoRealm.Request samanthaWith(String act, String jti) {
        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read");
        request.identityAttributes.put("act", List.of(act));
        if (jti != null) {
            request.identityAttributes.put("jti", List.of(jti));
        }
        return request;
    }

    JsonNode actorChain(DemoRealm.Request request) throws IOException {
        List<ObjectNode> requests = projection.requests(request.evaluation());
        assertEquals(1, requests.size());
        return requests.get(0).at("/facts/actor_chain");
    }

    static JsonNode json(String text) throws IOException {
        return Projection.JSON.readTree(text);
    }

    @Test
    void genuineDelegatedTokenIsProjectedAsAnActorChain() throws IOException {
        assertEquals(json("[{\"type\":\"service\",\"id\":\"research-agent\"}]"), actorChain(samanthaWith(AGENT_ACT, DELEGATED_JTI)));
        // lightweight access tokens carry "lt" as the token type
        assertEquals(json("[{\"type\":\"service\",\"id\":\"research-agent\"}]"),
                actorChain(samanthaWith(AGENT_ACT, "trltte:45dfa700-dfbd-007d-d579-49b0c15a662f")));
    }

    /**
     * Finding act-forged-by-protocol-mapper. "act" is not in OIDCAttributeMapperHelper's list of non-modifiable
     * claims, so a hardcoded-claim mapper (claim "act", JSON type JSON) or a user-attribute mapper on samantha-app
     * puts this exact claim into samantha's ordinary login token (authorization code grant, online session: jti
     * "onrtac:..."). Keycloak's delegation exchange never ran, and samantha never consented to research-agent.
     */
    @Test
    void actWrittenByAProtocolMapperOnALoginTokenIsNotADelegation() {
        DemoRealm.Request request = samanthaWith(AGENT_ACT, "onrtac:0b4c2f6e-1d7a-4a39-9d55-0d1c6b2f7e10");
        request.identityAttributes.put("sid", List.of("5f0c3f9e-7d0b-4f0e-a1c2-3b4d5e6f7a8b"));
        assertThrows(IllegalArgumentException.class, () -> projection.requests(request.evaluation()));
    }

    @Test
    void actOnAnyTokenNotIssuedByTheExchangeGrantOnATransientSessionIsNotADelegation() throws IOException {
        List<String> projected = new ArrayList<>();
        for (String jti : List.of(
                "trrtcc:3c7e", // client credentials (transient): a mapper on the agent's own client
                "onrtte:3c7e", // token exchange on an online session: standard exchange of a login token
                "onrtrt:3c7e", // refresh token grant
                "onrtpa:3c7e", // password grant
                "trrtte", // no ':' and no raw id
                "xtrrtte:3c7e", // prefix
                "TRRTTE:3c7e")) {
            try {
                projection.requests(samanthaWith(AGENT_ACT, jti).evaluation());
                projected.add(jti);
            } catch (IllegalArgumentException expected) {
                // not a delegation
            }
        }
        assertEquals(List.of(), projected, "act projected as a delegation on these tokens");
        // no jti at all: AuthZEN identities (UserModelIdentity, ClientModelIdentity) are not built from a token
        assertThrows(IllegalArgumentException.class, () -> projection.requests(samanthaWith(AGENT_ACT, null).evaluation()));
        // two jti values
        DemoRealm.Request twice = samanthaWith(AGENT_ACT, DELEGATED_JTI);
        twice.identityAttributes.put("jti", List.of(DELEGATED_JTI, "onrtac:3c7e"));
        assertThrows(IllegalArgumentException.class, () -> projection.requests(twice.evaluation()));
    }

    /**
     * Finding act-overloaded-by-impersonation. TokenManager.setActClaimFromImpersonator writes
     * act = {sub: impersonator id, preferred_username} on every token of an impersonation session (an online session
     * created by the admin impersonation endpoint). Without a provenance check the adapter projected it as
     * "helpdesk acts for samantha", the same shape the kernel requires for a consented delegation.
     */
    @Test
    void impersonationActIsNotADelegation() {
        demo.user("u-helpdesk", "helpdesk", null, List.of(), List.of());
        DemoRealm.Request request = samanthaWith("{\"sub\":\"u-helpdesk\",\"preferred_username\":\"helpdesk\"}",
                "onrtac:8a1e5c1b-2f3d-4e5f-8a9b-0c1d2e3f4a5b");
        request.identityAttributes.put("sid", List.of("6a7b8c9d-0e1f-4a2b-8c3d-4e5f6a7b8c9d"));
        assertThrows(IllegalArgumentException.class, () -> projection.requests(request.evaluation()));
    }

    /**
     * Impersonation and user delegation cannot be told apart by the act claim's shape alone: a user delegation copies
     * may_act, which the "may_act sub" mapper fills with only "sub", and an impersonation act without the
     * IMPERSONATOR_USERNAME note is also only "sub". The session (jti "tr...te:" vs an online session) is what
     * differs.
     */
    @Test
    void impersonationAndUserDelegationHaveTheSameActShape() throws IOException {
        demo.user("u-helpdesk", "helpdesk", null, List.of(), List.of());
        String userAct = "{\"sub\":\"u-helpdesk\"}";
        assertEquals(json("[{\"type\":\"user\",\"id\":\"helpdesk\"}]"), actorChain(samanthaWith(userAct, DELEGATED_JTI)));
        assertThrows(IllegalArgumentException.class,
                () -> projection.requests(samanthaWith(userAct, "onrtac:8a1e5c1b-2f3d-4e5f-8a9b-0c1d2e3f4a5b").evaluation()));
    }

    /**
     * Finding act-nested-from-actor-token (open). TokenExchangeDelegationProvider.checkRequestedAudiences nests the
     * ACTOR token's own "act" claim verbatim. A hardcoded "act" mapper on research-agent's client puts
     * {sub: summary-agent} into research-agent's client-credentials token; used as actor_token, it becomes the inner
     * link of a genuine delegated token. The outer token passes every check the adapter can make.
     */
    @Test
    void known_weakness_nestedActCopiedFromTheActorTokenIsProjected() throws IOException {
        String act = "{\"sub\":\"u-sa-research-agent\",\"client_id\":\"research-agent\",\"act\":{\"sub\":\"u-sa-summary-agent\"}}";
        assertEquals(json("[{\"type\":\"service\",\"id\":\"research-agent\"},{\"type\":\"service\",\"id\":\"summary-agent\"}]"),
                actorChain(samanthaWith(act, DELEGATED_JTI)));
    }

    /**
     * Finding act-from-user-attributes (open). Through AuthZEN, a USER subject's identity is a UserModelIdentity whose
     * attributes are the user's own attributes, and AuthZenResource.withSubjectProperties overlays PEP-supplied
     * subject.properties on them. A user allowed to edit unmanaged attributes (or the PEP) can set both "act" and
     * "jti"; nothing in Attributes says they did not come from a token.
     */
    @Test
    void known_weakness_actAndJtiSetAsUserAttributesAreProjected() throws IOException {
        // UserModelIdentity.getAttributes() is user.getAttributes(): profile attributes, no token claims (no iss, typ, azp).
        DemoRealm.Request request = samanthaWith(AGENT_ACT, DELEGATED_JTI);
        request.identityAttributes.put("firstName", List.of("Samantha"));
        request.identityAttributes.put("email", List.of("samantha@example.org"));
        assertEquals(json("[{\"type\":\"service\",\"id\":\"research-agent\"}]"), actorChain(request));
    }

    /**
     * Finding principal-id-is-mutable-username (open, by design of the wire format: user ids are usernames). Keycloak's
     * stable identity is the user id; the kernel's is the username, which an admin can change, a user can change when
     * the realm allows editing usernames, and a new user can take after the old one is deleted. Two different Keycloak
     * users project to the same principal, and the ledger's grants, delegations and prohibitions follow the name.
     */
    @Test
    void known_weakness_principalIdIsTheMutableUsername() throws IOException {
        demo.user("u-samantha-2", "samantha-2", null, List.of(), List.of());
        ObjectNode before = projection.requests(demo.request().identity(demo.samantha).scopes("read").evaluation()).get(0);
        // samantha is deleted; a self-registered user picks the freed username
        DemoRealm other = new DemoRealm();
        other.user("u-mallory", "samantha", null, List.of(), List.of());
        ObjectNode after = new Projection(ProjectionTest.FIXED).requests(other.request().identityId("u-mallory").scopes("read").evaluation()).get(0);
        assertEquals(before.at("/facts/subject"), after.at("/facts/subject"));
    }

    @Test
    void actTextWithDuplicateKeysIsRejected() {
        // Only reachable when a mapper writes "act" as a String claim, which KeycloakIdentity keeps verbatim.
        DemoRealm.Request request = samanthaWith("{\"sub\":\"u-sa-research-agent\",\"sub\":\"u-sa-summary-agent\"}", DELEGATED_JTI);
        assertThrows(IOException.class, () -> projection.requests(request.evaluation()));
    }

    // ---------------------------------------------------------------------------------------------------------
    // Pushed-claim type confusion. AuthorizationTokenService reads claim_token with JsonSerialization into a raw
    // Map and casts it to Map<String, List<String>>; ResourcePermission's constructor then copies every value with
    // Collection.addAll before any policy runs.
    // ---------------------------------------------------------------------------------------------------------

    @SuppressWarnings({"unchecked", "rawtypes"})
    static ResourcePermission permissionWithClaims(Map<String, Object> claims) {
        return new ResourcePermission(DemoRealm.resource("q3-report", "document"), List.of(DemoRealm.scope("read")), null, (Map) claims);
    }

    @Test
    void keycloakFailsOnScalarObjectAndNullClaimsBeforeAnyPolicyRuns() {
        assertThrows(ClassCastException.class, () -> permissionWithClaims(Map.of("mandate", "generate-report")));
        assertThrows(ClassCastException.class, () -> permissionWithClaims(Map.of("mandate", Map.of("x", 1))));
        Map<String, Object> nullEffect = new LinkedHashMap<>();
        nullEffect.put("effect", null);
        assertThrows(NullPointerException.class, () -> permissionWithClaims(nullEffect));
        // Lists of anything pass: these are the shapes that reach the policy.
        permissionWithClaims(Map.of("mandate", List.of(1, 2), "effect", Arrays.asList(null, true, Map.of("x", 1), List.of("a"))));
    }

    /**
     * Parser differential on claim_token: Keycloak decodes it with JsonSerialization.mapper (a default ObjectMapper:
     * no duplicate detection, trailing content ignored, lenient UTF-8). Only Keycloak's interpretation reaches the
     * adapter (a Map) and the kernel, so Java and OCaml never disagree about it; the requesting client, which writes
     * the claims, is the only party the leniency could mislead.
     */
    @Test
    @SuppressWarnings("unchecked")
    void keycloakResolvesAmbiguousClaimTokensBeforeTheAdapterSeesThem() throws IOException {
        Map<String, Object> dup = org.keycloak.util.JsonSerialization.readValue(
                "{\"mandate\":[\"publish-release\"],\"mandate\":[\"generate-report\"]}".getBytes(StandardCharsets.UTF_8), Map.class);
        assertEquals(List.of("generate-report"), dup.get("mandate"), "last duplicate wins");
        Map<String, Object> trailing = org.keycloak.util.JsonSerialization.readValue(
                "{\"mandate\":[\"generate-report\"]} {\"mandate\":[\"publish-release\"]}".getBytes(StandardCharsets.UTF_8), Map.class);
        assertEquals(List.of("generate-report"), trailing.get("mandate"), "a second document is ignored");
        byte[] overlong = "{\"mandate\":[\"generateÀ­report\"]}".getBytes(StandardCharsets.ISO_8859_1); // C0 AD: overlong '-'
        assertEquals(List.of("generate-report"), org.keycloak.util.JsonSerialization.readValue(overlong, Map.class).get("mandate"),
                "overlong UTF-8 is decoded, not rejected");
    }

    @Test
    void claimValuesThatReachThePolicyAreForwardedAsJsonForTheKernelToReject() throws IOException {
        JsonNode query = projection.requests(demo.request().identity(demo.samantha).scopes("read")
                .pushed("mandate", List.of(1, 2)).pushed("effect", List.of(Map.of("x", 1))).evaluation()).get(0).get("query");
        assertEquals(json("[1,2]"), query.get("mandate"));
        assertEquals(json("{\"x\":1}"), query.get("effect"));

        query = projection.requests(demo.request().identity(demo.samantha).scopes("read")
                .pushed("mandate", List.of(List.of("generate-report"))).pushed("effect", List.of(true)).evaluation()).get(0).get("query");
        assertEquals(json("[\"generate-report\"]"), query.get("mandate"));
        assertEquals(json("true"), query.get("effect"));

        // Not reachable through the token endpoint (see above), but handled: an object is forwarded as JSON, null is absent.
        Map<String, Object> odd = new LinkedHashMap<>();
        odd.put("effect", null);
        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read").pushed("mandate", Map.of("x", 1));
        request.pushedClaims.putAll(odd);
        query = projection.requests(request.evaluation()).get(0).get("query");
        assertEquals(json("{\"x\":1}"), query.get("mandate"));
        assertFalse(query.has("effect"));
    }

    // ---------------------------------------------------------------------------------------------------------
    // Process protocol: what counts as the kernel's answer.
    // ---------------------------------------------------------------------------------------------------------

    static final String AUTHORITY = "\"authority\":{\"grant\":\"g-stub\",\"chain\":[],\"anchor\":\"stub\"}";

    /** A shell printf of a decision/v1 document for this request whose remaining members are {@code tail}. */
    static String printfDecision(String tail) {
        return "printf '{\"schema\":\"typed-authority/decision/v1\",\"request_id\":\"%s\"," + tail + "}' \"$id\"";
    }

    static final String VALID_ALLOW = printfDecision("\"decision\":\"allow\"," + AUTHORITY + ",\"reasons\":[]");

    int grants(Path kernel, Duration timeout) {
        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read")
                .pushed("mandate", List.of("generate-report")).pushed("effect", List.of("observe")).ledger(ProjectionTest.LEDGER);
        new TypedAuthorityPolicyProvider(new Projection(ProjectionTest.FIXED), new Kernel(kernel, timeout, null)).evaluate(request.evaluation());
        return request.grants;
    }

    int grants(String name, String body) throws IOException {
        return grants(FailClosedTest.stub(name, body), Duration.ofSeconds(10));
    }

    @Test
    void aFullyValidAllowGrants() throws IOException {
        assertEquals(1, grants("boundary-valid-allow", VALID_ALLOW));
    }

    @Test
    void partialOutputThenHangDoesNotGrantAndReturnsAtTheTimeout() throws IOException {
        Path kernel = FailClosedTest.stub("boundary-partial-hang", printfDecision("\"decision\":\"allow\"").replace("}' \"$id\"", "' \"$id\"")
                + "; exec sleep 30");
        long start = System.nanoTime();
        assertEquals(0, grants(kernel, Duration.ofMillis(500)));
        assertTrue(Duration.ofNanos(System.nanoTime() - start).compareTo(Duration.ofSeconds(5)) < 0);
    }

    @Test
    void twoDocumentsDoNotGrant() throws IOException {
        String deny = printfDecision("\"decision\":\"deny\",\"reasons\":[{\"code\":\"no_grant_for_capability\",\"message\":\"-\"}]");
        assertEquals(0, grants("boundary-deny-then-allow", deny + "; " + VALID_ALLOW));
        assertEquals(0, grants("boundary-allow-then-allow", VALID_ALLOW + "; " + VALID_ALLOW));
        assertEquals(0, grants("boundary-allow-then-nul", VALID_ALLOW + "; printf '\\000'"));
    }

    @Test
    void decisionAllowAloneDoesNotGrant() throws IOException {
        assertEquals(0, grants("boundary-bare-allow", "printf '{\"decision\":\"allow\"}'"));
    }

    /** Finding decision-allow-without-authority: wire-format.md says authority is present iff the decision is allow. */
    @Test
    void allowWithoutAuthorityDoesNotGrant() throws IOException {
        Map<String, Integer> granted = new LinkedHashMap<>();
        granted.put("bare", grants("boundary-allow-no-authority", printfDecision("\"decision\":\"allow\"")));
        granted.put("reasons only", grants("boundary-allow-no-authority-reasons", printfDecision("\"decision\":\"allow\",\"reasons\":[]")));
        granted.put("null", grants("boundary-allow-null-authority", printfDecision("\"decision\":\"allow\",\"authority\":null,\"reasons\":[]")));
        granted.put("string", grants("boundary-allow-string-authority", printfDecision("\"decision\":\"allow\",\"authority\":\"yes\",\"reasons\":[]")));
        assertEquals(Map.of("bare", 0, "reasons only", 0, "null", 0, "string", 0), granted);
    }

    /** Same finding: reasons is non-empty iff the decision is not allow. */
    @Test
    void allowWithReasonsOrWithoutAReasonsArrayDoesNotGrant() throws IOException {
        Map<String, Integer> granted = new LinkedHashMap<>();
        granted.put("with reasons", grants("boundary-allow-with-reasons", printfDecision("\"decision\":\"allow\"," + AUTHORITY
                + ",\"reasons\":[{\"code\":\"expired\",\"message\":\"-\"}]")));
        granted.put("reasons null", grants("boundary-allow-reasons-null", printfDecision("\"decision\":\"allow\"," + AUTHORITY + ",\"reasons\":null")));
        granted.put("no reasons", grants("boundary-allow-no-reasons", printfDecision("\"decision\":\"allow\"," + AUTHORITY)));
        assertEquals(Map.of("with reasons", 0, "reasons null", 0, "no reasons", 0), granted);
    }

    @Test
    void decisionSpellingsOtherThanAllowDoNotGrant() throws IOException {
        for (String verdict : List.of("ALLOW", "Allow", " allow", "allow ", "allowed", "permit", "true")) {
            assertEquals(0, grants("boundary-spelling-" + verdict.trim().toLowerCase(),
                    printfDecision("\"decision\":\"" + verdict + "\"," + AUTHORITY + ",\"reasons\":[]")), verdict);
        }
        assertEquals(0, grants("boundary-decision-true", printfDecision("\"decision\":true," + AUTHORITY + ",\"reasons\":[]")));
    }

    @Test
    void duplicateKeysAnywhereInTheDecisionDoNotGrant() throws IOException {
        assertEquals(0, grants("boundary-dup-nested", printfDecision("\"decision\":\"allow\",\"authority\":{\"grant\":\"a\",\"grant\":\"b\"},\"reasons\":[]")));
        assertEquals(0, grants("boundary-dup-request-id", printfDecision("\"request_id\":\"other\",\"decision\":\"allow\"," + AUTHORITY + ",\"reasons\":[]")));
    }

    @Test
    void exitZeroWithOnlyWhitespaceDoesNotGrant() throws IOException {
        assertEquals(0, grants("boundary-whitespace", "printf ' \\n\\t\\n'"));
    }

    @Test
    void sixteenMebibytesOfStderrAreDrained() throws IOException {
        assertEquals(1, grants("boundary-stderr-16m", "head -c 16777216 /dev/zero >&2; " + VALID_ALLOW));
    }

    /**
     * Finding decision-encoding-lenient. RFC 8259 JSON exchanged between systems is UTF-8 without a BOM, and the
     * kernel's own parser (tjson) rejects all of these. Jackson's byte-level reader auto-detects UTF-16/32,
     * skips a UTF-8 BOM and decodes overlong sequences (C1 A1 is an overlong 'a').
     */
    @Test
    void decisionThatIsNotStrictUtf8DoesNotGrant() throws IOException {
        Map<String, Integer> granted = new LinkedHashMap<>();
        granted.put("bom", grants("boundary-bom", "printf '\\357\\273\\277'; " + VALID_ALLOW));
        granted.put("utf16le", grants("boundary-utf16le", VALID_ALLOW + " | iconv -f UTF-8 -t UTF-16LE"));
        granted.put("utf32be", grants("boundary-utf32be", VALID_ALLOW + " | iconv -f UTF-8 -t UTF-32BE"));
        granted.put("overlong", grants("boundary-overlong", printfDecision("\"decision\":\"\\301\\241llow\"," + AUTHORITY + ",\"reasons\":[]")));
        assertEquals(Map.of("bom", 0, "utf16le", 0, "utf32be", 0, "overlong", 0), granted);
    }

    @Test
    void aGrandchildHoldingStdoutOpenDoesNotGrantAndReturnsAtTheTimeout() throws IOException {
        // The stub answers and exits 0, but a background process keeps the pipe open, so stdout never ends.
        Path kernel = FailClosedTest.stub("boundary-grandchild", "(sleep 3 &); " + VALID_ALLOW);
        long start = System.nanoTime();
        assertEquals(0, grants(kernel, Duration.ofMillis(500)));
        assertTrue(Duration.ofNanos(System.nanoTime() - start).compareTo(Duration.ofSeconds(2)) < 0);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Evidence leakage: the only effect of a decision on the evaluation is grant().
    // ---------------------------------------------------------------------------------------------------------

    @Test
    void nothingTheKernelReturnsReachesTheEvaluationExceptGrant() throws IOException {
        Path kernel = FailClosedTest.stub("boundary-evidence-marker", printfDecision("\"decision\":\"allow\"," + AUTHORITY
                + ",\"reasons\":[],\"evidence\":{\"secret\":\"LEDGER-STRUCTURE-MARKER\"}"));
        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read")
                .pushed("mandate", List.of("generate-report")).pushed("effect", List.of("observe")).ledger(ProjectionTest.LEDGER);
        Evaluation inner = request.evaluation();
        List<String> calls = new ArrayList<>();
        Evaluation recording = (Evaluation) Proxy.newProxyInstance(getClass().getClassLoader(), new Class<?>[] {Evaluation.class},
                (proxy, method, args) -> {
                    calls.add(method.getName());
                    return method.invoke(inner, args);
                });
        new TypedAuthorityPolicyProvider(new Projection(ProjectionTest.FIXED), new Kernel(kernel, Duration.ofSeconds(10), null)).evaluate(recording);

        assertEquals(1, request.grants);
        assertTrue(Set.of("getAuthorizationProvider", "getContext", "getPolicy", "getPermission", "grant").containsAll(calls), calls.toString());
        assertEquals(1, calls.stream().filter("grant"::equals).count());
        // No claims were added to the permission Keycloak turns into the RPT or the {"result": true} response.
        assertTrue(inner.getPermission().getClaims().isEmpty(), inner.getPermission().getClaims().toString());
    }

    // ---------------------------------------------------------------------------------------------------------
    // Parser differential, Java side: what Jackson (as the adapter configures it) makes of ledger text. The kernel
    // never sees the raw text: it gets Jackson's re-serialisation, or the text as a JSON string when Jackson
    // rejects it. test/boundary/test_boundary.ml feeds the same inputs to tjson.
    // ---------------------------------------------------------------------------------------------------------

    static final String LEDGER_WITH_DEPTH = "{\"schema\":\"typed-authority/ledger/v1\",\"principals\":[],\"mandates\":[],"
            + "\"grants\":[{\"id\":\"g\",\"delegable_depth\":1,\"purpose\":\"Produce\"}],\"prohibitions\":[]}";

    static Map<String, String> ambiguousLedgers() {
        String l = LEDGER_WITH_DEPTH;
        Map<String, String> inputs = new LinkedHashMap<>();
        inputs.put("duplicate top-level key", l.replace("\"grants\":", "\"grants\":[],\"grants\":"));
        inputs.put("duplicate key inside a grant", l.replace("\"id\":\"g\"", "\"id\":\"g\",\"id\":\"h\""));
        inputs.put("duplicate key spelled with an escape", l.replace("\"grants\":", "\"grants\":[],\"gr\\u0061nts\":"));
        inputs.put("trailing comma", l.replace("\"prohibitions\":[]", "\"prohibitions\":[],"));
        inputs.put("comment", l.replace("\"prohibitions\":[]", "\"prohibitions\":[] /* none */"));
        inputs.put("NaN", l.replace("\"delegable_depth\":1", "\"delegable_depth\":NaN"));
        inputs.put("Infinity", l.replace("\"delegable_depth\":1", "\"delegable_depth\":Infinity"));
        inputs.put("leading zero", l.replace("\"delegable_depth\":1", "\"delegable_depth\":01"));
        inputs.put("single quotes", l.replace("\"prohibitions\"", "'prohibitions'"));
        inputs.put("BOM before the ledger", "\uFEFF" + l);
        inputs.put("vertical tab as whitespace", l.replace("\"prohibitions\":", "\"prohibitions\":\u000B"));
        inputs.put("NBSP as whitespace", l.replace("\"prohibitions\":", "\"prohibitions\":\u00A0"));
        inputs.put("raw control character in a string", l.replace("Produce", "Pro\u0001duce"));
        inputs.put("two documents", l + " " + l);
        return inputs;
    }

    @Test
    void jacksonRejectsEveryAmbiguousLedgerTextSoTheKernelGetsItAsAString() throws IOException {
        for (Map.Entry<String, String> input : ambiguousLedgers().entrySet()) {
            JsonNode ledger = projection.requests(demo.request().identity(demo.samantha).scopes("read").ledger(input.getValue()).evaluation())
                    .get(0).get("ledger");
            assertTrue(ledger.isTextual(), input.getKey() + ": " + ledger);
            assertEquals(input.getValue(), ledger.textValue(), input.getKey());
        }
    }

    /** The bytes the kernel receives for ledger values Jackson accepts but re-spells. */
    @Test
    void jacksonReserialisesLedgerNumbersAndStrings() throws IOException {
        String[][] cases = {
            {"\"delegable_depth\":1e2", "\"delegable_depth\":100.0"},
            {"\"delegable_depth\":1E2", "\"delegable_depth\":100.0"},
            {"\"delegable_depth\":-0", "\"delegable_depth\":0"},
            {"\"delegable_depth\":1E400", "\"delegable_depth\":\"Infinity\""},
            {"\"delegable_depth\":99999999999999999999", "\"delegable_depth\":99999999999999999999"},
            {"\"purpose\":\"\\uD800Produce\"", "\"purpose\":\"\\uD800Produce\""},
            {"\"id\":\"g\\u0000\"", "\"id\":\"g\\u0000\""},
            {"\"purpose\":\"\\u0050roduce\"", "\"purpose\":\"Produce\""},
        };
        for (String[] c : cases) {
            String original = c[0].startsWith("\"delegable_depth\"") ? "\"delegable_depth\":1" : c[0].startsWith("\"id\"") ? "\"id\":\"g\"" : "\"purpose\":\"Produce\"";
            String text = LEDGER_WITH_DEPTH.replace(original, c[0]);
            ObjectNode request = projection.requests(demo.request().identity(demo.samantha).scopes("read").ledger(text).evaluation()).get(0);
            String sent = new String(Projection.JSON.writeValueAsBytes(request), StandardCharsets.UTF_8);
            assertTrue(sent.contains(c[1]), c[0] + " -> " + sent);
        }
    }

    /** The evidence directory and the log are the only places the decision document goes. */
    @Test
    void evidenceFilesAreNamedByTheAdaptersOwnRequestId() throws IOException {
        Path evidence = FailClosedTest.STUBS.resolve("boundary-evidence-" + System.nanoTime());
        Path kernel = FailClosedTest.stub("boundary-evidence-name", VALID_ALLOW);
        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read");
        new TypedAuthorityPolicyProvider(new Projection(ProjectionTest.FIXED), new Kernel(kernel, Duration.ofSeconds(10), evidence))
                .evaluate(request.evaluation());
        try (Stream<Path> files = Files.list(evidence)) {
            List<String> names = files.map(p -> p.getFileName().toString()).toList();
            assertEquals(1, names.size());
            assertTrue(names.get(0).matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.json"), names.get(0));
        }
    }
}
