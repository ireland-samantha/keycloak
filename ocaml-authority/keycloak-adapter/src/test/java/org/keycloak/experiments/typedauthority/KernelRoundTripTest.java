package org.keycloak.experiments.typedauthority;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.stream.Stream;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

/**
 * Adapter + real OCaml kernel, on fake Keycloak state shaped like the demo realm. Runs only when the system
 * property typed.authority.kernel names an executable kernel ({@code mvn test -Dtyped.authority.kernel=PATH}).
 */
class KernelRoundTripTest {

    static Path kernel;
    static String ledger;

    final DemoRealm demo = new DemoRealm();

    @BeforeAll
    static void loadLedger() throws IOException {
        String path = System.getProperty("typed.authority.kernel");
        kernel = path != null && Files.isExecutable(Path.of(path)) ? Path.of(path).toAbsolutePath() : null;
        try (InputStream in = KernelRoundTripTest.class.getResourceAsStream("/roundtrip-ledger.json")) {
            ledger = new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    @BeforeEach
    void requireKernel() {
        // Per test rather than per class, so that surefire reports the tests as skipped.
        assumeTrue(kernel != null, "typed.authority.kernel does not name an executable");
    }

    /** Evaluates one request with the real kernel; returns the kernel's decision document and the grant count. */
    record Outcome(JsonNode decision, int grants) {
    }

    Outcome evaluate(DemoRealm.Request request) throws IOException {
        Path evidence = FailClosedTest.STUBS.resolve("roundtrip-evidence-" + System.nanoTime());
        new TypedAuthorityPolicyProvider(new Projection(ProjectionTest.FIXED), new Kernel(kernel, Duration.ofSeconds(10), evidence))
                .evaluate(request.evaluation());
        try (Stream<Path> files = Files.list(evidence)) {
            List<Path> decisions = files.toList();
            assertEquals(1, decisions.size(), "one scope, one decision document");
            return new Outcome(Projection.JSON.readTree(decisions.get(0).toFile()), request.grants);
        }
    }

    DemoRealm.Request readUnderGenerateReport(String ledgerText) {
        return demo.request().resource(demo.q3Report).scopes("read")
                .pushed("mandate", List.of("generate-report")).pushed("effect", List.of("observe")).ledger(ledgerText);
    }

    /** This test's ledger, and the committed demo ledger (examples/scenarios/demo.json) when a kernel is there to use it. */
    static Stream<Arguments> ledgers() throws IOException {
        Path demo = Path.of("..", "examples", "scenarios", "demo.json");
        Arguments own = Arguments.of("roundtrip-ledger.json", ledger);
        if (kernel == null || !Files.exists(demo)) {
            return Stream.of(own);
        }
        return Stream.of(own, Arguments.of("examples/scenarios/demo.json", Projection.JSON.readTree(demo.toFile()).get("ledger").toString()));
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("ledgers")
    void scenario01DirectReadIsAllowed(String source, String ledgerText) throws IOException {
        // run-demo.sh 01-direct-read: the agent's own token, q3-report#read, generate-report, observe.
        Outcome outcome = evaluate(readUnderGenerateReport(ledgerText).identity(demo.researchAgentAccount));

        assertEquals("allow", outcome.decision().get("decision").textValue(), outcome.decision().toString());
        assertEquals("g-agent-read", outcome.decision().at("/authority/grant").textValue());
        assertEquals(1, outcome.grants());
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("ledgers")
    void scenario05ExpiredDelegationIsDenied(String source, String ledgerText) throws IOException {
        // run-demo.sh 05-expired-delegation: samantha's token exchanged by research-agent, same request.
        Outcome outcome = evaluate(readUnderGenerateReport(ledgerText).identity(demo.samantha).actors(demo.researchAgentAccount));

        assertEquals("deny", outcome.decision().get("decision").textValue(), outcome.decision().toString());
        assertTrue(outcome.decision().toString().contains("expired"), outcome.decision().toString());
        assertEquals(0, outcome.grants());
    }

    @Test
    void removingTheAnchorRoleInKeycloakRevokesDelegatedAuthority() throws IOException {
        // Hypothesis S5 through the adapter: same ledger, same token; only the live role mapping changes.
        String current = ledger.replace("\"valid_until\": \"2026-09-01T00:00:00Z\"", "\"valid_until\": \"2026-12-31T23:59:59Z\"");
        assertEquals(1, evaluate(readUnderGenerateReport(current).identity(demo.samantha).actors(demo.researchAgentAccount)).grants());

        demo.samanthaGroups.clear();   // samantha leaves "authors", the only source of report-author
        Outcome outcome = evaluate(readUnderGenerateReport(current).identity(demo.samantha).actors(demo.researchAgentAccount));

        assertEquals(0, outcome.grants(), outcome.decision().toString());
    }
}
