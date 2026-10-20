package org.keycloak.experiments.typedauthority;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * The adversarial inputs of {@link BoundaryAttackTest}, through the adapter and the real OCaml kernel. Runs only
 * when the system property typed.authority.kernel names an executable kernel.
 */
class BoundaryRoundTripTest {

    static Path kernel;
    /** roundtrip-ledger.json with the delegation d-agent-read-for-samantha current, as in the S5 round trip. */
    static String ledger;

    final DemoRealm demo = new DemoRealm();

    @BeforeAll
    static void load() throws IOException {
        String path = System.getProperty("typed.authority.kernel");
        kernel = path != null && Files.isExecutable(Path.of(path)) ? Path.of(path).toAbsolutePath() : null;
        try (InputStream in = BoundaryRoundTripTest.class.getResourceAsStream("/roundtrip-ledger.json")) {
            ledger = new String(in.readAllBytes(), StandardCharsets.UTF_8)
                    .replace("\"valid_until\": \"2026-09-01T00:00:00Z\"", "\"valid_until\": \"2026-12-31T23:59:59Z\"");
        }
    }

    @BeforeEach
    void requireKernel() {
        assumeTrue(kernel != null, "typed.authority.kernel does not name an executable");
    }

    /** The kernel's decision document (null when no kernel answer was kept as evidence) and the grant count. */
    record Outcome(JsonNode decision, int grants) {

        String verdict() {
            return decision == null ? "(none)" : decision.get("decision").textValue();
        }

        List<String> codes() {
            List<String> codes = new ArrayList<>();
            if (decision != null) {
                decision.path("reasons").forEach(reason -> codes.add(reason.path("code").textValue()));
            }
            return codes;
        }
    }

    Outcome evaluate(DemoRealm.Request request, Duration timeout) throws IOException {
        Path evidence = FailClosedTest.STUBS.resolve("boundary-roundtrip-" + System.nanoTime());
        new TypedAuthorityPolicyProvider(new Projection(ProjectionTest.FIXED), new Kernel(kernel, timeout, evidence)).evaluate(request.evaluation());
        if (!Files.exists(evidence)) {
            return new Outcome(null, request.grants);
        }
        try (Stream<Path> files = Files.list(evidence)) {
            List<Path> decisions = files.toList();
            assertTrue(decisions.size() <= 1, "one scope, at most one decision document");
            return new Outcome(decisions.isEmpty() ? null : Projection.JSON.readTree(decisions.get(0).toFile()), request.grants);
        }
    }

    Outcome evaluate(DemoRealm.Request request) throws IOException {
        return evaluate(request, Duration.ofSeconds(10));
    }

    DemoRealm.Request read(String ledgerText) {
        return demo.request().resource(demo.q3Report).scopes("read")
                .pushed("mandate", List.of("generate-report")).pushed("effect", List.of("observe")).ledger(ledgerText);
    }

    @Test
    void controlTheAgentsOwnReadAndTheLiveDelegationAreAllowed() throws IOException {
        assertEquals(1, evaluate(read(ledger).identity(demo.researchAgentAccount)).grants());
        Outcome delegated = evaluate(read(ledger).identity(demo.samantha).actors(demo.researchAgentAccount));
        assertEquals("d-agent-read-for-samantha", delegated.decision().at("/authority/grant").textValue(), delegated.decision().toString());
        assertEquals(1, delegated.grants());
    }

    /** Finding act-forged-by-protocol-mapper, end to end on fakes: before the fix this was allowed through d-agent-read-for-samantha. */
    @Test
    void mapperActOnALoginTokenIsNotAllowedThroughTheDelegatedGrant() throws IOException {
        DemoRealm.Request request = read(ledger).identity(demo.samantha);
        request.identityAttributes.put("act", List.of("{\"sub\":\"u-sa-research-agent\",\"client_id\":\"research-agent\"}"));
        request.identityAttributes.put("jti", List.of("onrtac:4a16c2ae-c379-6d30-2885-6c8dc6af6915"));
        Outcome outcome = evaluate(request);
        assertEquals(0, outcome.grants());
        assertNull(outcome.decision(), "the kernel is not asked");
    }

    /** Parser differential: every ambiguous ledger text reaches the kernel as a JSON string and is malformed. */
    @Test
    void ambiguousLedgerTextsAreMalformedNeverAllowed() throws IOException {
        Map<String, String> inputs = new LinkedHashMap<>();
        inputs.put("duplicate top-level key", ledger.replaceFirst("\"grants\":", "\"grants\": [], \"grants\":"));
        inputs.put("duplicate key in a grant", ledger.replaceFirst("\"id\": \"g-agent-read\"", "\"id\": \"g-agent-read\", \"id\": \"g-other\""));
        inputs.put("duplicate key spelled with an escape", ledger.replaceFirst("\"grants\":", "\"grants\": [], \"gr\\\\u0061nts\":"));
        inputs.put("trailing comma", ledger.replaceFirst("\\]\\s*}\\s*$", "],}"));
        inputs.put("comment", ledger.replaceFirst("\"grants\":", "/* c */ \"grants\":"));
        inputs.put("NaN depth", ledger.replaceFirst("\"delegable_depth\": 1", "\"delegable_depth\": NaN"));
        inputs.put("leading zero depth", ledger.replaceFirst("\"delegable_depth\": 1", "\"delegable_depth\": 01"));
        inputs.put("BOM", "﻿" + ledger);
        inputs.put("two documents", ledger + ledger);
        for (Map.Entry<String, String> input : inputs.entrySet()) {
            Outcome outcome = evaluate(read(input.getValue()).identity(demo.researchAgentAccount));
            assertEquals(0, outcome.grants(), input.getKey());
            assertEquals(List.of("malformed_request"), outcome.codes(), input.getKey());
        }
    }

    /** Parser differential: numbers Jackson accepts and re-spells are still not integers to the kernel. */
    @Test
    void reserialisedLedgerNumbersAreMalformedNeverAllowed() throws IOException {
        for (String lexeme : List.of("1e0", "1E0", "1.0", "1E400", "99999999999999999999")) {
            Outcome outcome = evaluate(read(ledger.replaceFirst("\"delegable_depth\": 1", "\"delegable_depth\": " + lexeme))
                    .identity(demo.samantha).actors(demo.researchAgentAccount));
            assertEquals(0, outcome.grants(), lexeme);
            assertEquals(List.of("malformed_request"), outcome.codes(), lexeme + " " + outcome.decision());
        }
        // -0 is the integer 0 on both sides: the parent can no longer delegate.
        Outcome zero = evaluate(read(ledger.replaceFirst("\"delegable_depth\": 1", "\"delegable_depth\": -0"))
                .identity(demo.samantha).actors(demo.researchAgentAccount));
        assertEquals(0, zero.grants());
        assertTrue(zero.codes().contains("delegation_depth_exceeded"), zero.codes().toString());
    }

    /** Pushed claims that pass AuthorizationTokenService and ResourcePermission, as the kernel sees them. */
    @Test
    void pushedClaimTypeConfusionIsMalformedOrMissingNeverAllowed() throws IOException {
        Map<String, Object[]> cases = new LinkedHashMap<>();
        cases.put("mandate [1,2]", new Object[] {"mandate", List.of(1, 2), "malformed_request"});
        cases.put("mandate [7]", new Object[] {"mandate", List.of(7), "malformed_request"});
        cases.put("mandate [{x:1}]", new Object[] {"mandate", List.of(Map.of("x", 1)), "malformed_request"});
        cases.put("mandate [[generate-report]]", new Object[] {"mandate", List.of(List.of("generate-report")), "malformed_request"});
        cases.put("mandate twice", new Object[] {"mandate", List.of("generate-report", "generate-report"), "malformed_request"});
        cases.put("effect [true]", new Object[] {"effect", List.of(true), "malformed_request"});
        cases.put("effect [null]", new Object[] {"effect", java.util.Arrays.asList((Object) null), "missing_effect"});
        cases.put("effect [OBSERVE]", new Object[] {"effect", List.of("OBSERVE"), "malformed_request"});
        cases.put("effect [produce: organization]", new Object[] {"effect", List.of("produce: organization"), "malformed_request"});
        for (Map.Entry<String, Object[]> c : cases.entrySet()) {
            Outcome outcome = evaluate(read(ledger).identity(demo.researchAgentAccount).pushed((String) c.getValue()[0], c.getValue()[1]));
            assertEquals(0, outcome.grants(), c.getKey());
            assertTrue(outcome.codes().contains((String) c.getValue()[2]), c.getKey() + ": " + outcome.codes());
        }
    }

    /**
     * Finding tjson-duplicate-key-quadratic. A confidential client controls claim_token. Keycloak caps it at 20,000
     * characters by default (OIDCProviderConfig, token-parameter limit, fail-fast); an object with ~12.8k distinct keys
     * needs a raised limit. The adapter forwards whatever arrives, and the kernel's duplicate-key detection was
     * quadratic in the number of keys, so this case pins the kernel's side of the fix.
     */
    @Test
    void aClaimSizedObjectWithManyKeysIsDecidedWellWithinTheTimeout() throws IOException {
        Map<String, Integer> object = new LinkedHashMap<>();
        for (int i = 0; object.size() < 12_782; i++) {
            object.put(Integer.toString(i, 36), 0);
        }
        long start = System.nanoTime();
        Outcome outcome = evaluate(read(ledger).identity(demo.researchAgentAccount).pushed("mandate", List.of(object)), Duration.ofMillis(1000));
        Duration took = Duration.ofNanos(System.nanoTime() - start);
        assertNotNull(outcome.decision(), "no decision within 1 s (took " + took.toMillis() + " ms)");
        assertEquals(List.of("malformed_request"), outcome.codes());
    }

    /**
     * Finding unrepresentable-role-name (open). Keycloak allows role and client names the wire format's identifier
     * syntax does not ([A-Za-z0-9._:@-]{1,128}), e.g. "Report Author" or a client id that is a URL. The adapter
     * projects every live role of the subject and the actors, so one such role makes every request of that
     * principal malformed: fail closed, but a denial of service by configuration, whatever the ledger says.
     */
    @Test
    void known_weakness_oneUnrepresentableRoleMakesEveryRequestOfItsHolderMalformed() throws IOException {
        demo.samanthaGroups.add(DemoRealm.group("g-display", null, DemoRealm.role(demo.realm, "Report Author")));
        Outcome outcome = evaluate(read(ledger).identity(demo.samantha));
        assertEquals(0, outcome.grants());
        assertEquals(List.of("malformed_request"), outcome.codes());
        assertTrue(outcome.decision().at("/reasons/0/message").textValue().contains("realm_roles"), outcome.decision().toString());
    }

    /**
     * Finding oversize-request-evidence. A request over 1 MiB (here: a padded ledger) is answered with
     * request_too_large before the kernel has read it all, and the kernel exits, so writing the rest of the request
     * fails with a broken pipe. The kernel's answer must still be kept as evidence (README: every decision document).
     */
    @Test
    void anOversizeRequestIsNotGrantedAndItsVerdictIsKept() throws IOException {
        String padded = ledger.replaceFirst("\"schema\"", "\"pad\": \"" + "x".repeat(2 * 1024 * 1024) + "\", \"schema\"");
        Outcome outcome = evaluate(read(padded).identity(demo.researchAgentAccount));
        assertEquals(0, outcome.grants());
        assertEquals(List.of("request_too_large"), outcome.codes());
    }
}
