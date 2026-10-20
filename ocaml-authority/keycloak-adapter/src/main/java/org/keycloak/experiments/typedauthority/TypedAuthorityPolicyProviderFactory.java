package org.keycloak.experiments.typedauthority;

import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import java.util.HashMap;

import org.jboss.logging.Logger;
import org.keycloak.Config;
import org.keycloak.authorization.AuthorizationProvider;
import org.keycloak.authorization.model.Policy;
import org.keycloak.authorization.policy.provider.PolicyProvider;
import org.keycloak.authorization.policy.provider.PolicyProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.representations.idm.authorization.PolicyRepresentation;

/**
 * Policy type "typed-authority". SPI options (Keycloak scope policy/typed-authority):
 * {@code kernel-path} (fallback: env TYPED_AUTHORITY_KERNEL), {@code timeout-ms} (default 2000),
 * {@code evidence-dir} (optional). The ledger is the policy's config entry "ledger".
 *
 * <p>Config persistence needs no hook here: for a PolicyRepresentation-typed provider,
 * RepresentationToModel.toModel stores {@code representation.getConfig()} on every create, update and
 * realm import, and then calls onImport. Only the typed read path goes through {@link #toRepresentation}.
 */
public final class TypedAuthorityPolicyProviderFactory implements PolicyProviderFactory<PolicyRepresentation> {

    public static final String ID = "typed-authority";
    static final String KERNEL_ENV = "TYPED_AUTHORITY_KERNEL";
    static final long DEFAULT_TIMEOUT_MS = 2000;

    private static final Logger LOG = Logger.getLogger(TypedAuthorityPolicyProviderFactory.class);

    private TypedAuthorityPolicyProvider provider;

    @Override
    public void init(Config.Scope config) {
        String kernel = config.get("kernel-path", System.getenv(KERNEL_ENV));
        String evidence = config.get("evidence-dir");
        long timeoutMs = config.getLong("timeout-ms", DEFAULT_TIMEOUT_MS);
        if (kernel == null) {
            LOG.warnf("no kernel configured (kernel-path or %s): every %s policy will fail closed", KERNEL_ENV, ID);
        }
        provider = new TypedAuthorityPolicyProvider(new Projection(Clock.systemUTC()), new Kernel(
                kernel == null ? null : Path.of(kernel), Duration.ofMillis(timeoutMs), evidence == null ? null : Path.of(evidence)));
        LOG.infof("%s: kernel=%s timeout-ms=%d evidence-dir=%s", ID, kernel, timeoutMs, evidence);
    }

    @Override
    public PolicyProvider create(AuthorizationProvider authorization) {
        return provider;
    }

    @Override
    public PolicyProvider create(KeycloakSession session) {
        return provider;
    }

    @Override
    public PolicyRepresentation toRepresentation(Policy policy, AuthorizationProvider authorization) {
        PolicyRepresentation representation = new PolicyRepresentation();
        representation.setConfig(new HashMap<>(policy.getConfig()));
        return representation;
    }

    @Override
    public Class<PolicyRepresentation> getRepresentationType() {
        return PolicyRepresentation.class;
    }

    @Override
    public String getId() {
        return ID;
    }

    @Override
    public String getName() {
        return "Typed authority (OCaml kernel)";
    }

    @Override
    public String getGroup() {
        return "Experimental";
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
    }

    @Override
    public void close() {
    }
}
