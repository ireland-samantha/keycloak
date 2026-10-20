package org.keycloak.experiments.typedauthority;

import java.io.IOException;
import java.time.Clock;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Stream;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.NullNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.fasterxml.jackson.databind.node.TextNode;
import org.keycloak.authorization.AuthorizationProvider;
import org.keycloak.authorization.attribute.Attributes;
import org.keycloak.authorization.identity.Identity;
import org.keycloak.authorization.model.Resource;
import org.keycloak.authorization.model.Scope;
import org.keycloak.authorization.policy.evaluation.Evaluation;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.utils.RoleUtils;

/**
 * Keycloak state to typed-authority/request/v1 (wire-format.md). Copies and reshapes; decides nothing.
 * Values the kernel must judge (the pushed claims "mandate" and "effect", the policy config "ledger") are
 * forwarded even when malformed.
 */
final class Projection {

    static final String REQUEST_SCHEMA = "typed-authority/request/v1";
    /** RFC 8693 actor claim. This fork declares it as IDToken.ACT; Keycloak 26.7.4 does not. */
    static final String ACT = "act";

    /** Duplicate keys and trailing content are parse errors, as in the kernel's own codec. */
    static final ObjectMapper JSON = new ObjectMapper()
            .enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
            .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);

    private final Clock clock;

    Projection(Clock clock) {
        this.clock = clock;
    }

    /** One request per scope of the permission, in the permission's scope order. */
    List<ObjectNode> requests(Evaluation evaluation) throws IOException {
        AuthorizationProvider authorization = evaluation.getAuthorizationProvider();
        KeycloakSession session = authorization.getKeycloakSession();
        RealmModel realm = authorization.getRealm();
        Identity identity = evaluation.getContext().getIdentity();

        Principal subject = resolve(session, realm, identity.getId());
        List<Principal> actors = actorIds(identity.getAttributes()).stream().map(id -> resolve(session, realm, id)).toList();
        Map<JsonNode, ObjectNode> principals = new LinkedHashMap<>();
        Stream.concat(Stream.of(subject), actors.stream())
                .forEach(principal -> principals.computeIfAbsent(principal.reference(), reference -> principal.roleFacts()));
        ObjectNode facts = JSON.createObjectNode()
                .put("source", "keycloak")
                .put("realm", realm.getName())
                .put("evaluated_at", DateTimeFormatter.ISO_INSTANT.format(clock.instant().truncatedTo(ChronoUnit.SECONDS)));
        facts.set("subject", subject.reference());
        facts.putArray("actor_chain").addAll(actors.stream().map(Principal::reference).toList());
        facts.putArray("principals").addAll(principals.values());

        JsonNode ledger = ledger(evaluation.getPolicy().getConfig().get("ledger"));
        Resource resource = evaluation.getPermission().getResource();
        Attributes pushed = evaluation.getContext().getAttributes();
        List<ObjectNode> requests = new ArrayList<>();
        for (Scope scope : evaluation.getPermission().getScopes()) {
            ObjectNode request = JSON.createObjectNode()
                    .put("schema", REQUEST_SCHEMA)
                    .put("request_id", UUID.randomUUID().toString());
            ObjectNode query = request.putObject("query");
            putPushedClaim(query, pushed, "mandate", JSON::valueToTree);
            query.putObject("capability")
                    .put("resource_type", resource == null ? null : resource.getType())
                    .put("action", scope.getName());
            query.put("resource", resource == null ? null : resource.getName());
            putPushedClaim(query, pushed, "effect", Projection::effect);
            request.set("facts", facts);
            request.set("ledger", ledger);
            requests.add(request);
        }
        return requests;
    }

    /** Subject or actor as the kernel names it: service accounts by client_id, users by username. */
    private record Principal(String type, String id, UserModel user) {

        ObjectNode reference() {
            return JSON.createObjectNode().put("type", type).put("id", id);
        }

        /** Live effective roles: direct, composite and group-inherited mappings. */
        ObjectNode roleFacts() {
            TreeSet<String> realmRoles = new TreeSet<>();
            TreeMap<String, TreeSet<String>> clientRoles = new TreeMap<>();
            for (RoleModel role : RoleUtils.getDeepUserRoleMappings(user)) {
                if (role.getContainer() instanceof ClientModel client) {
                    clientRoles.computeIfAbsent(client.getClientId(), c -> new TreeSet<>()).add(role.getName());
                } else if (role.getContainer() instanceof RealmModel) {
                    realmRoles.add(role.getName());
                }
            }
            ObjectNode facts = reference();
            realmRoles.forEach(facts.putArray("realm_roles")::add);
            ObjectNode byClient = facts.putObject("client_roles");
            clientRoles.forEach((client, roles) -> roles.forEach(byClient.putArray(client)::add));
            return facts;
        }
    }

    private static Principal resolve(KeycloakSession session, RealmModel realm, String id) {
        UserModel user = session.users().getUserById(realm, id);
        if (user == null) {
            // KeycloakIdentity uses the client's internal id when a resource server presents its own service-account token.
            ClientModel client = realm.getClientById(id);
            user = client == null ? null : session.users().getServiceAccount(client);
        }
        if (user == null) {
            throw new IllegalStateException("no user or service account with id " + id + " in realm " + realm.getName());
        }
        String clientLink = user.getServiceAccountClientLink();
        if (clientLink == null) {
            return new Principal("user", user.getUsername(), user);
        }
        ClientModel client = realm.getClientById(clientLink);
        if (client == null) {
            throw new IllegalStateException("service account " + user.getId() + " links to missing client " + clientLink);
        }
        return new Principal("service", client.getClientId(), user);
    }

    /**
     * RFC 8693 actor chain, current actor first. KeycloakIdentity keeps a JSON-object claim as one JSON text value.
     * "act" is only a claim: protocol mappers and admin impersonation (TokenManager.setActClaimFromImpersonator) write
     * it too. TokenExchangeDelegationProvider always issues on a new transient session through the token-exchange
     * grant, which DefaultTokenContextEncoderProvider encodes in the jti (mappers cannot set it) as "tr" + token type
     * + "te:". Any other "act" is not a Keycloak-verified delegation, and this adapter has no way to say so to the kernel.
     */
    private static List<String> actorIds(Attributes identity) throws IOException {
        Object claim = identity.toMap().get(ACT);
        if (claim == null) {
            return List.of();
        }
        if (!(claim instanceof Collection<?> values) || values.size() != 1 || !(values.iterator().next() instanceof String text)) {
            throw new IllegalArgumentException("identity attribute 'act' is not one JSON text: " + claim);
        }
        List<String> ids = new ArrayList<>();
        for (JsonNode act = JSON.readTree(text); act != null; act = act.get(ACT)) {
            if (!act.isObject() || !act.path("sub").isTextual()) {
                throw new IllegalArgumentException("'act' is not a chain of objects with a string 'sub': " + text);
            }
            ids.add(act.get("sub").textValue());
        }
        Collection<String> jti = identity.toMap().getOrDefault("jti", List.of());
        if (jti.size() != 1 || !String.valueOf(jti.iterator().next()).matches("tr(rt|lt)te:.+")) {
            throw new IllegalArgumentException("'act' on a token no delegation exchange issued (jti " + jti + "): " + text);
        }
        return ids;
    }

    /**
     * An UMA pushed claim. AuthorizationTokenService decodes claim_token into Map&lt;String, List&lt;String&gt;&gt;
     * through an unchecked cast, so any JSON value may arrive. No value: field omitted; one: that value;
     * several: an array (which the kernel rejects).
     */
    private static void putPushedClaim(ObjectNode query, Attributes pushed, String name, Function<Object, JsonNode> encode) {
        Object claim = pushed.toMap().get(name);
        List<Object> values = new ArrayList<>();
        if (claim instanceof Collection<?> collection) {
            values.addAll(collection);
        } else if (claim != null) {
            values.add(claim);
        }
        if (values.size() == 1) {
            query.set(name, encode.apply(values.get(0)));
        } else if (values.size() > 1) {
            query.putArray(name).addAll(values.stream().map(encode).toList());
        }
    }

    /** "kind" or "kind:audience", split at the first ':'. The kernel validates both parts. */
    private static JsonNode effect(Object value) {
        if (!(value instanceof String text)) {
            return JSON.valueToTree(value);
        }
        int colon = text.indexOf(':');
        ObjectNode effect = JSON.createObjectNode().put("kind", colon < 0 ? text : text.substring(0, colon));
        return colon < 0 ? effect : effect.put("audience", text.substring(colon + 1));
    }

    /** The parsed ledger, or its raw text as a JSON string when it is not strict JSON (the kernel then reports it). */
    static JsonNode ledger(String text) {
        if (text == null) {
            return NullNode.getInstance();
        }
        try {
            JsonNode tree = JSON.readTree(text);
            return tree == null || tree.isMissingNode() ? TextNode.valueOf(text) : tree;
        } catch (IOException e) {
            return TextNode.valueOf(text);
        }
    }
}
