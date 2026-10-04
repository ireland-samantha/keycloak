package org.keycloak.experiments.typedauthority;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.stream.Stream;

import org.junit.jupiter.api.Test;

/**
 * The provider grants only when a kernel process answers "allow", with exit status 0, within the timeout, in a
 * strict decision/v1 document of at most 4 MiB for the same request_id. The kernels here are shell scripts
 * written into target/kernel-stubs.
 */
class FailClosedTest {

    static final Path STUBS = Path.of("target", "kernel-stubs").toAbsolutePath();

    /**
     * Reads the request, records it, and defines decide VERDICT [REASONS_JSON]. An allow carries an "authority"
     * object, as every allow of the real kernel does (wire-format.md), and the adapter requires.
     */
    static final String PRELUDE = """
            [ "$1" = eval ] || exit 64
            request=$(cat)
            printf '%s\\n' "$request" >> "$0.log"
            id=$(printf '%s' "$request" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
            action=$(printf '%s' "$request" | sed -n 's/.*"action":"\\([^"]*\\)".*/\\1/p')
            decide() {
              authority=; [ "$1" = allow ] && authority='"authority":{"grant":"g-stub","chain":[],"anchor":"stub"},'
              printf '{"schema":"typed-authority/decision/v1","request_id":"%s","decision":"%s",%s"reasons":[%s]}\\n' "$id" "$1" "$authority" "$2"
            }
            """;

    final DemoRealm demo = new DemoRealm();

    static Path stub(String name, String body) throws IOException {
        Path script = Files.createDirectories(STUBS).resolve(name);
        Files.writeString(script, "#!/bin/sh\n" + PRELUDE + body + "\n");
        Files.deleteIfExists(log(script));
        assertTrue(script.toFile().setExecutable(true));
        return script;
    }

    static Path log(Path stub) {
        return stub.resolveSibling(stub.getFileName() + ".log");
    }

    static long requestsSeen(Path stub) throws IOException {
        return Files.exists(log(stub)) ? Files.readAllLines(log(stub)).size() : 0;
    }

    TypedAuthorityPolicyProvider provider(Path kernel, Duration timeout, Path evidenceDir) {
        return new TypedAuthorityPolicyProvider(new Projection(ProjectionTest.FIXED), new Kernel(kernel, timeout, evidenceDir));
    }

    /** Grants after one evaluation of samantha reading q3-report under generate-report/observe. */
    int grants(Path kernel, Duration timeout, String... scopes) {
        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes(scopes)
                .pushed("mandate", List.of("generate-report")).pushed("effect", List.of("observe"))
                .ledger(ProjectionTest.LEDGER);
        provider(kernel, timeout, null).evaluate(request.evaluation());
        return request.grants;
    }

    int grants(Path kernel) {
        return grants(kernel, Duration.ofSeconds(10), "read");
    }

    @Test
    void allowGrants() throws IOException {
        Path kernel = stub("allow", "decide allow");
        assertEquals(1, grants(kernel));
        assertEquals(1, requestsSeen(kernel));
    }

    @Test
    void denyDoesNotGrant() throws IOException {
        assertEquals(0, grants(stub("deny", "decide deny '{\"code\":\"no_grant_for_capability\",\"message\":\"-\"}'")));
    }

    @Test
    void indeterminateDoesNotGrant() throws IOException {
        assertEquals(0, grants(stub("indeterminate", "decide indeterminate '{\"code\":\"missing_mandate\",\"message\":\"-\"}'")));
    }

    @Test
    void timeoutDoesNotGrantAndKillsTheKernel() throws IOException {
        Path kernel = stub("timeout", "exec sleep 30");
        long start = System.nanoTime();
        assertEquals(0, grants(kernel, Duration.ofMillis(300), "read"));
        assertTrue(Duration.ofNanos(System.nanoTime() - start).compareTo(Duration.ofSeconds(5)) < 0);
    }

    @Test
    void nonZeroExitDoesNotGrantEvenWithAnAllowDocument() throws IOException {
        assertEquals(0, grants(stub("exit-3", "decide allow; echo 'kernel failed' >&2; exit 3")));
    }

    @Test
    void garbageStdoutDoesNotGrant() throws IOException {
        assertEquals(0, grants(stub("garbage", "echo 'allow'")));
    }

    @Test
    void emptyStdoutDoesNotGrant() throws IOException {
        assertEquals(0, grants(stub("empty", "true")));
    }

    @Test
    void oversizeStdoutDoesNotGrantEvenWhenItIsAValidAllow() throws IOException {
        // A syntactically valid allow document, padded past the 4 MiB cap.
        assertEquals(0, grants(stub("oversize", """
                printf '{"schema":"typed-authority/decision/v1","request_id":"%s","decision":"allow","authority":{},"reasons":[],"pad":"' "$id"
                head -c 4194304 /dev/zero | tr '\\000' x
                printf '"}\\n'""")));
    }

    @Test
    void decisionForAnotherRequestDoesNotGrant() throws IOException {
        assertEquals(0, grants(stub("other-request", "id=someone-else; decide allow")));
    }

    @Test
    void allowWithNullRequestIdDoesNotGrant() throws IOException {
        assertEquals(0, grants(stub("allow-null-id", "printf '{\"schema\":\"typed-authority/decision/v1\",\"request_id\":null,\"decision\":\"allow\",\"authority\":{},\"reasons\":[]}'")));
    }

    @Test
    void undecodableRequestVerdictIsKeptAsEvidence() throws IOException {
        // The real kernel answers a request it cannot decode with request_id null (malformed_request).
        Path kernel = stub("malformed", """
                printf '{"schema":"typed-authority/decision/v1","request_id":null,"decision":"indeterminate","reasons":[{"code":"malformed_request","message":"$.query.mandate"}]}'""");
        Path evidence = STUBS.resolve("evidence-" + System.nanoTime());
        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read");
        provider(kernel, Duration.ofSeconds(10), evidence).evaluate(request.evaluation());

        assertEquals(0, request.grants);
        try (Stream<Path> files = Files.list(evidence)) {
            assertEquals("malformed_request",
                    Projection.JSON.readTree(files.findFirst().orElseThrow().toFile()).at("/reasons/0/code").textValue());
        }
    }

    @Test
    void decisionWithoutSchemaDoesNotGrant() throws IOException {
        assertEquals(0, grants(stub("no-schema", "printf '{\"request_id\":\"%s\",\"decision\":\"allow\",\"authority\":{},\"reasons\":[]}' \"$id\"")));
    }

    @Test
    void duplicateDecisionKeyDoesNotGrant() throws IOException {
        assertEquals(0, grants(stub("duplicate-key", """
                printf '{"schema":"typed-authority/decision/v1","request_id":"%s","decision":"deny","decision":"allow","reasons":[]}' "$id\"""")));
    }

    @Test
    void trailingContentDoesNotGrant() throws IOException {
        assertEquals(0, grants(stub("trailing", "decide allow; echo '{}'")));
    }

    @Test
    void missingKernelDoesNotGrant() {
        assertEquals(0, grants(STUBS.resolve("no-such-kernel")));
        assertEquals(0, grants(null));
    }

    @Test
    void chattyStderrIsDrained() throws IOException {
        // 1 MiB of stderr would fill the pipe and block the kernel if the adapter did not read it.
        assertEquals(1, grants(stub("stderr", "head -c 1048576 /dev/zero >&2; decide allow")));
    }

    @Test
    void everyScopeMustBeAllowed() throws IOException {
        Path kernel = stub("read-only", "if [ \"$action\" = read ]; then decide allow; else decide deny; fi");
        assertEquals(0, grants(kernel, Duration.ofSeconds(10), "read", "generate"));
        assertEquals(2, requestsSeen(kernel));
        assertEquals(1, grants(kernel, Duration.ofSeconds(10), "read"));
    }

    @Test
    void permissionWithoutScopeIsNotGrantedAndNotAsked() throws IOException {
        Path kernel = stub("unasked", "decide allow");
        assertEquals(0, grants(kernel, Duration.ofSeconds(10)));
        assertEquals(0, requestsSeen(kernel));
    }

    @Test
    void projectionFailureDoesNotGrantAndDoesNotAsk() throws IOException {
        Path kernel = stub("unreachable", "decide allow");
        DemoRealm.Request request = demo.request().identityId("deleted-user").scopes("read");
        provider(kernel, Duration.ofSeconds(10), null).evaluate(request.evaluation());
        assertEquals(0, request.grants);
        assertEquals(0, requestsSeen(kernel));
    }

    @Test
    void decisionsAreWrittenToTheEvidenceDirectory() throws IOException {
        Path kernel = stub("evidence", "decide deny '{\"code\":\"no_grant_for_capability\",\"message\":\"-\"}'");
        Path evidence = STUBS.resolve("evidence-" + System.nanoTime());
        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read", "generate");
        provider(kernel, Duration.ofSeconds(10), evidence).evaluate(request.evaluation());

        List<Path> files;
        try (Stream<Path> listing = Files.list(evidence)) {
            files = listing.sorted().toList();
        }
        List<String> sent = Files.readAllLines(log(kernel));
        assertEquals(2, files.size());
        for (Path file : files) {
            String requestId = file.getFileName().toString().replaceFirst("\\.json$", "");
            assertTrue(sent.stream().anyMatch(line -> line.contains("\"request_id\":\"" + requestId + "\"")));
            assertEquals("deny", Projection.JSON.readTree(file.toFile()).get("decision").textValue());
        }
    }

    @Test
    void evidenceIsTheKernelsBytes() throws IOException {
        Path kernel = stub("evidence-bytes", "decide allow");
        Path evidence = STUBS.resolve("evidence-" + System.nanoTime());
        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read");
        provider(kernel, Duration.ofSeconds(10), evidence).evaluate(request.evaluation());

        assertEquals(1, request.grants);
        try (Stream<Path> listing = Files.list(evidence)) {
            Path file = listing.findFirst().orElseThrow();
            String id = file.getFileName().toString().replaceFirst("\\.json$", "");
            assertArrayEquals(("{\"schema\":\"typed-authority/decision/v1\",\"request_id\":\"" + id
                    + "\",\"decision\":\"allow\",\"authority\":{\"grant\":\"g-stub\",\"chain\":[],\"anchor\":\"stub\"},\"reasons\":[]}\n").getBytes(),
                    Files.readAllBytes(file));
        }
    }
}
