package org.keycloak.experiments.typedauthority;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;
import static org.keycloak.experiments.typedauthority.Fakes.fake;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Stream;

import org.junit.jupiter.api.Test;
import org.keycloak.Config;
import org.keycloak.authorization.model.Policy;
import org.keycloak.authorization.policy.provider.PolicyProviderFactory;
import org.keycloak.representations.idm.authorization.PolicyRepresentation;

class FactoryTest {

    final DemoRealm demo = new DemoRealm();

    /** A Keycloak SPI scope (policy/typed-authority) holding the given options. */
    static Config.Scope scope(Map<String, String> options) {
        return fake(Config.Scope.class,
                "get", (Fakes.Answer) args -> options.getOrDefault((String) args[0], args.length > 1 ? (String) args[1] : null),
                "getLong", (Fakes.Answer) args -> options.containsKey((String) args[0])
                        ? Long.valueOf(options.get((String) args[0])) : (Long) args[1],
                "getPropertyNames", Set.copyOf(options.keySet()));
    }

    @Test
    void identity() {
        TypedAuthorityPolicyProviderFactory factory = new TypedAuthorityPolicyProviderFactory();
        assertEquals("typed-authority", factory.getId());
        assertEquals("Experimental", factory.getGroup());
        assertSame(PolicyRepresentation.class, factory.getRepresentationType());
    }

    @Test
    void registeredAsPolicyProviderFactory() throws IOException {
        String service = "META-INF/services/" + PolicyProviderFactory.class.getName();
        try (InputStream in = getClass().getClassLoader().getResourceAsStream(service)) {
            assertEquals(List.of(TypedAuthorityPolicyProviderFactory.class.getName()),
                    new String(in.readAllBytes(), StandardCharsets.UTF_8).lines().toList());
        }
    }

    @Test
    void typedRepresentationCarriesTheConfig() {
        Map<String, String> stored = Map.of("ledger", ProjectionTest.LEDGER);
        Policy policy = fake(Policy.class, "getConfig", stored);

        PolicyRepresentation representation = new TypedAuthorityPolicyProviderFactory().toRepresentation(policy, null);

        assertEquals(stored, representation.getConfig());
        representation.getConfig().put("other", "x");   // a copy: JPA's getConfig() is unmodifiable
    }

    @Test
    void spiOptionsConfigureKernelTimeoutAndEvidence() throws IOException {
        Path kernel = FailClosedTest.stub("configured", "decide allow");
        Path evidence = FailClosedTest.STUBS.resolve("configured-evidence-" + System.nanoTime());
        Map<String, String> options = new HashMap<>();
        options.put("kernel-path", kernel.toString());
        options.put("timeout-ms", "5000");
        options.put("evidence-dir", evidence.toString());
        TypedAuthorityPolicyProviderFactory factory = new TypedAuthorityPolicyProviderFactory();
        factory.init(scope(options));

        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read");
        factory.create(new org.keycloak.authorization.AuthorizationProvider(demo.session, demo.realm, null))
                .evaluate(request.evaluation());

        assertEquals(1, request.grants);
        try (Stream<Path> files = Files.list(evidence)) {
            assertEquals(1, files.count());
        }
    }

    @Test
    void timeoutOptionIsHonoured() throws IOException {
        Path kernel = FailClosedTest.stub("slow", "sleep 1; decide allow");
        TypedAuthorityPolicyProviderFactory factory = new TypedAuthorityPolicyProviderFactory();
        factory.init(scope(Map.of("kernel-path", kernel.toString(), "timeout-ms", "200")));

        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read");
        factory.create(demo.session).evaluate(request.evaluation());

        assertEquals(0, request.grants);
    }

    @Test
    void withoutKernelEverythingFailsClosed() {
        assumeTrue(System.getenv(TypedAuthorityPolicyProviderFactory.KERNEL_ENV) == null, "TYPED_AUTHORITY_KERNEL is set");
        TypedAuthorityPolicyProviderFactory factory = new TypedAuthorityPolicyProviderFactory();
        factory.init(scope(Map.of()));

        DemoRealm.Request request = demo.request().identity(demo.samantha).scopes("read");
        factory.create(demo.session).evaluate(request.evaluation());

        assertEquals(0, request.grants);
        assertTrue(request.policyConfig.isEmpty());
    }
}
