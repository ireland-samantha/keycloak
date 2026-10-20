package org.keycloak.experiments.typedauthority;

import java.util.ArrayList;
import java.util.List;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.jboss.logging.Logger;
import org.keycloak.authorization.policy.evaluation.Evaluation;
import org.keycloak.authorization.policy.provider.PolicyProvider;

/**
 * Grants iff the kernel answers "allow" for every scope of the permission. Every other outcome, including
 * any failure to obtain an answer, leaves the evaluation without a grant (fail closed) and is logged.
 */
final class TypedAuthorityPolicyProvider implements PolicyProvider {

    private static final Logger LOG = Logger.getLogger(TypedAuthorityPolicyProvider.class);

    private final Projection projection;
    private final Kernel kernel;

    TypedAuthorityPolicyProvider(Projection projection, Kernel kernel) {
        this.projection = projection;
        this.kernel = kernel;
    }

    @Override
    public void evaluate(Evaluation evaluation) {
        String policy = evaluation.getPolicy().getName();
        try {
            // The kernel's capability is resource_type:action; without a scope there is no action to ask about.
            if (evaluation.getPermission().getScopes().isEmpty()) {
                LOG.infof("%s policy '%s': permission names no scope, not granted", TypedAuthorityPolicyProviderFactory.ID, policy);
                return;
            }
            boolean allAllowed = true;
            for (ObjectNode request : projection.requests(evaluation)) {
                JsonNode decision = kernel.decide(request);
                String verdict = decision.get("decision").textValue();
                List<String> codes = new ArrayList<>();
                decision.path("reasons").forEach(reason -> codes.add(reason.path("code").asText()));
                LOG.infof("%s policy '%s' request %s: %s:%s on %s -> %s %s", TypedAuthorityPolicyProviderFactory.ID, policy,
                        request.get("request_id").textValue(), request.at("/query/capability/resource_type").asText(),
                        request.at("/query/capability/action").asText(), request.at("/query/resource").asText(), verdict, codes);
                allAllowed &= "allow".equals(verdict);
            }
            if (allAllowed) {
                evaluation.grant();
            }
        } catch (Kernel.Failure e) {
            LOG.warnf("%s policy '%s': not granted, kernel failed: %s", TypedAuthorityPolicyProviderFactory.ID, policy, e.getMessage());
        } catch (Exception e) {
            LOG.warnf(e, "%s policy '%s': not granted", TypedAuthorityPolicyProviderFactory.ID, policy);
        }
    }

    @Override
    public void close() {
    }
}
