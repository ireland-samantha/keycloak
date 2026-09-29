package org.keycloak.experiments.typedauthority;

import static org.keycloak.experiments.typedauthority.Fakes.fake;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.keycloak.authorization.AuthorizationProvider;
import org.keycloak.authorization.attribute.Attributes;
import org.keycloak.authorization.identity.Identity;
import org.keycloak.authorization.model.Policy;
import org.keycloak.authorization.model.Resource;
import org.keycloak.authorization.model.Scope;
import org.keycloak.authorization.permission.ResourcePermission;
import org.keycloak.authorization.policy.evaluation.Evaluation;
import org.keycloak.authorization.policy.evaluation.EvaluationContext;
import org.keycloak.models.ClientModel;
import org.keycloak.models.GroupModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;

/**
 * Fake Keycloak state shaped like examples/keycloak/realm-template.json, plus a second agent
 * (summary-agent) for two-deep actor chains. samantha's roles exercise every path of the deep role
 * mapping: direct, composite (realm and client roles) and inherited from a group and its parent group.
 */
final class DemoRealm {

    static final String NAME = "typed-authority-demo";
    /** The jti of a delegated token, as this fork issues it (captured by verify-live.sh). */
    static final String DELEGATED_JTI = "trrtte:45dfa700-dfbd-007d-d579-49b0c15a662f";

    private final Map<String, UserModel> users = new LinkedHashMap<>();
    private final Map<String, ClientModel> clients = new HashMap<>();

    final RealmModel realm = fake(RealmModel.class,
            "getId", "r-demo",
            "getName", NAME,
            "getClientById", (Fakes.Answer) args -> clients.get((String) args[0]));

    final KeycloakSession session = fake(KeycloakSession.class, "users", fake(UserProvider.class,
            "getUserById", (Fakes.Answer) args -> users.get((String) args[1]),
            "getServiceAccount", (Fakes.Answer) args -> users.values().stream()
                    .filter(user -> ((ClientModel) args[0]).getId().equals(user.getServiceAccountClientLink()))
                    .findFirst().orElse(null)));

    final ClientModel documentService = client("c-document-service", "document-service");
    final ClientModel researchAgent = client("c-research-agent", "research-agent");
    final ClientModel summaryAgent = client("c-summary-agent", "summary-agent");

    final RoleModel reader = role(documentService, "reader");
    final RoleModel offlineAccess = role(realm, "offline_access");
    final RoleModel umaAuthorization = role(realm, "uma_authorization");
    final RoleModel defaultRoles = role(realm, "default-roles-typed-authority-demo", offlineAccess, umaAuthorization);
    final RoleModel reportAuthor = role(realm, "report-author");
    final RoleModel documentPublisher = role(realm, "document-publisher", reader);
    final RoleModel realmOperator = role(realm, "realm-operator");

    final GroupModel staff = group("g-staff", null, documentPublisher);
    final GroupModel authors = group("g-authors", staff, reportAuthor);

    /** Mutable, to change samantha's live role mappings between evaluations. */
    final List<GroupModel> samanthaGroups = new ArrayList<>(List.of(authors));
    final UserModel samantha = user("u-samantha", "samantha", null, List.of(defaultRoles, realmOperator), samanthaGroups);
    final UserModel researchAgentAccount = user("u-sa-research-agent", "service-account-research-agent", researchAgent,
            List.of(defaultRoles, reader), List.of());
    final UserModel summaryAgentAccount = user("u-sa-summary-agent", "service-account-summary-agent", summaryAgent,
            List.of(defaultRoles), List.of());

    final Resource q3Report = resource("q3-report", "document");
    final Resource realmConfig = resource("realm-config", "admin-surface");

    ClientModel client(String id, String clientId) {
        ClientModel client = fake(ClientModel.class, "getId", id, "getClientId", clientId);
        clients.put(id, client);
        return client;
    }

    static RoleModel role(Object container, String name, RoleModel... composites) {
        return fake(RoleModel.class,
                "getId", "role-" + name,
                "getName", name,
                "getContainer", container,
                "isClientRole", container instanceof ClientModel,
                "isComposite", composites.length > 0,
                "getCompositesStream", (Fakes.Answer) args -> Arrays.stream(composites));
    }

    static GroupModel group(String id, GroupModel parent, RoleModel... roles) {
        return fake(GroupModel.class,
                "getId", id,
                "getParentId", parent == null ? null : parent.getId(),
                "getParent", parent,
                "getRoleMappingsStream", (Fakes.Answer) args -> Arrays.stream(roles));
    }

    UserModel user(String id, String username, ClientModel serviceAccountOf, List<RoleModel> roles, List<GroupModel> groups) {
        UserModel user = fake(UserModel.class,
                "getId", id,
                "getUsername", username,
                "getServiceAccountClientLink", serviceAccountOf == null ? null : serviceAccountOf.getId(),
                "getRoleMappingsStream", (Fakes.Answer) args -> roles.stream(),
                "getGroupsStream", (Fakes.Answer) args -> groups.stream());
        users.put(id, user);
        return user;
    }

    static Resource resource(String name, String type) {
        return fake(Resource.class, "getName", name, "getType", type);
    }

    static Scope scope(String name) {
        return fake(Scope.class, "getName", name);
    }

    /** An RFC 8693 act claim as KeycloakIdentity stores it: the JSON text of the object. Current actor first. */
    static String act(UserModel... actors) {
        String act = null;
        for (int i = actors.length - 1; i >= 0; i--) {
            act = "{\"sub\":\"" + actors[i].getId() + "\"" + (act == null ? "" : ",\"act\":" + act) + "}";
        }
        return act;
    }

    Request request() {
        return new Request();
    }

    /** One policy evaluation: identity, UMA pushed claims, the permission and the policy's config. */
    final class Request {
        String identityId;
        final Map<String, Collection<String>> identityAttributes = new HashMap<>();
        final Map<String, Object> pushedClaims = new HashMap<>();
        Resource resource = q3Report;
        final List<Scope> scopes = new ArrayList<>();
        final Map<String, String> policyConfig = new HashMap<>();
        int grants;

        Request identity(UserModel user) {
            identityId = user.getId();
            return this;
        }

        Request identityId(String id) {
            identityId = id;
            return this;
        }

        /** A delegated token: act, and the jti of a token-exchange token on a transient session (see Projection). */
        Request actors(UserModel... chain) {
            identityAttributes.put("act", List.of(act(chain)));
            identityAttributes.put("jti", List.of(DELEGATED_JTI));
            return this;
        }

        Request pushed(String claim, Object value) {
            pushedClaims.put(claim, value);
            return this;
        }

        Request resource(Resource resource) {
            this.resource = resource;
            return this;
        }

        Request scopes(String... names) {
            Arrays.stream(names).map(DemoRealm::scope).forEach(scopes::add);
            return this;
        }

        Request ledger(String text) {
            policyConfig.put("ledger", text);
            return this;
        }

        @SuppressWarnings({"unchecked", "rawtypes"})
        Evaluation evaluation() {
            // AuthorizationTokenService builds the context attributes from claim_token with an unchecked cast;
            // the same raw map reaches the policy here.
            Map<String, Collection<String>> pushed = (Map) new HashMap<>(pushedClaims);
            Identity identity = fake(Identity.class, "getId", identityId, "getAttributes", Attributes.from(identityAttributes));
            EvaluationContext context = fake(EvaluationContext.class, "getIdentity", identity, "getAttributes", Attributes.from(pushed));
            Policy policy = fake(Policy.class, "getName", "typed-authority-kernel", "getConfig", policyConfig);
            return fake(Evaluation.class,
                    "getAuthorizationProvider", new AuthorizationProvider(session, realm, null),
                    "getContext", context,
                    "getPolicy", policy,
                    "getPermission", new ResourcePermission(resource, scopes, null),
                    "grant", (Fakes.Answer) args -> grants++);
        }
    }
}
