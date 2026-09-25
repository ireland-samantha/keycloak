/*
 * Copyright 2026 Red Hat, Inc. and/or its affiliates
 * and other contributors as indicated by the @author tags.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.keycloak.services.resources.account;

import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.List;

import org.keycloak.credential.CredentialModel;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.SubjectCredentialManager;
import org.keycloak.models.UserModel;
import org.keycloak.services.ErrorResponseException;
import org.keycloak.services.managers.Auth;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

/**
 * The Account API must apply the same credential label rule as the Admin API
 * ({@code UserResource#setCredentialUserLabel}): an empty or blank label is rejected with 400.
 */
public class AccountCredentialResourceTest {

    private static final String CREDENTIAL_ID = "cred-1";

    private final List<String> updatedLabels = new ArrayList<>();

    @Test
    public void shouldRejectEmptyCredentialLabelLikeAdminApi() {
        AccountCredentialResource resource = newResource();

        for (String jsonLabel : new String[] { "\"\"", "\"   \"", "null" }) {
            ErrorResponseException ex = assertThrows("label " + jsonLabel + " must be rejected",
                    ErrorResponseException.class, () -> resource.setLabel(CREDENTIAL_ID, jsonLabel));
            assertEquals("missingCredentialLabel", ex.getError());
            assertEquals(400, ex.getResponse().getStatus());
        }

        assertTrue("credential label must not be updated, but was set to " + updatedLabels, updatedLabels.isEmpty());
    }

    @Test
    public void shouldUpdateNonEmptyCredentialLabel() {
        newResource().setLabel(CREDENTIAL_ID, "\"My Phone\"");

        assertEquals(List.of("My Phone"), updatedLabels);
    }

    private AccountCredentialResource newResource() {
        CredentialModel credential = new CredentialModel();
        credential.setId(CREDENTIAL_ID);

        SubjectCredentialManager credentialManager = proxy(SubjectCredentialManager.class, (method, args) -> switch (method) {
            case "getStoredCredentialById" -> CREDENTIAL_ID.equals(args[0]) ? credential : null;
            case "updateCredentialLabel" -> {
                updatedLabels.add((String) args[1]);
                yield null;
            }
            default -> null;
        });
        UserModel user = proxy(UserModel.class, (method, args) -> "credentialManager".equals(method) ? credentialManager : null);
        KeycloakContext context = proxy(KeycloakContext.class, (method, args) -> null);
        KeycloakSession session = proxy(KeycloakSession.class, (method, args) -> "getContext".equals(method) ? context : null);

        Auth auth = new Auth(null, null, user, null, null, false) {
            @Override
            public void require(String role) {
                // caller is authorized
            }
        };

        return new AccountCredentialResource(session, user, auth, null);
    }

    private interface Handler {
        Object handle(String method, Object[] args);
    }

    @SuppressWarnings("unchecked")
    private static <T> T proxy(Class<T> type, Handler handler) {
        return (T) Proxy.newProxyInstance(AccountCredentialResourceTest.class.getClassLoader(), new Class[] { type },
                (proxy, method, args) -> {
                    if (method.getDeclaringClass() == Object.class) {
                        return switch (method.getName()) {
                            case "hashCode" -> System.identityHashCode(proxy);
                            case "equals" -> proxy == args[0];
                            default -> type.getSimpleName() + "Stub";
                        };
                    }
                    return handler.handle(method.getName(), args);
                });
    }
}
