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

package org.keycloak.theme;

import java.io.File;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.stream.Stream;

import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.theme.freemarker.DefaultFreeMarkerProviderFactory;
import org.keycloak.theme.freemarker.FreeMarkerProvider;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import static org.keycloak.theme.Theme.Type.LOGIN;

import static org.junit.Assert.assertEquals;

public class DefaultThemeManagerFactoryTest {

    @Rule
    public final TemporaryFolder temporaryFolder = new TemporaryFolder();

    @Test
    public void clearCacheAlsoClearsCachedTemplates() throws Exception {
        File themeDir = temporaryFolder.newFolder("login");
        Path template = themeDir.toPath().resolve("test.ftl");
        Files.writeString(template, "version-1", StandardCharsets.UTF_8);
        Theme theme = new FolderTheme(themeDir, "custom", LOGIN);

        DefaultFreeMarkerProviderFactory freeMarkerFactory = new DefaultFreeMarkerProviderFactory();
        FreeMarkerProvider freeMarker = freeMarkerFactory.create(null);

        DefaultThemeManagerFactory themeManagerFactory = new DefaultThemeManagerFactory();
        themeManagerFactory.postInit(sessionFactoryWith(freeMarkerFactory));

        assertEquals("version-1", freeMarker.processTemplate(new HashMap<>(), "test.ftl", theme));

        Files.writeString(template, "version-2", StandardCharsets.UTF_8);
        themeManagerFactory.clearCache();

        assertEquals("version-2", freeMarker.processTemplate(new HashMap<>(), "test.ftl", theme));
    }

    private static KeycloakSessionFactory sessionFactoryWith(DefaultFreeMarkerProviderFactory freeMarkerFactory) {
        return (KeycloakSessionFactory) Proxy.newProxyInstance(DefaultThemeManagerFactoryTest.class.getClassLoader(),
                new Class<?>[] { KeycloakSessionFactory.class }, (proxy, method, args) -> {
                    if (method.getName().equals("getProviderFactoriesStream") && args[0] == FreeMarkerProvider.class) {
                        return Stream.of(freeMarkerFactory);
                    }
                    throw new UnsupportedOperationException(method.getName());
                });
    }
}
