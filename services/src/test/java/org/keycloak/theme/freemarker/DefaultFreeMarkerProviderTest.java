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

package org.keycloak.theme.freemarker;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.concurrent.ConcurrentHashMap;

import org.keycloak.theme.FolderTheme;
import org.keycloak.theme.Theme;

import freemarker.template.Template;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import static org.keycloak.theme.Theme.Type.LOGIN;

import static org.junit.Assert.assertEquals;

public class DefaultFreeMarkerProviderTest {

    @Rule
    public final TemporaryFolder temporaryFolder = new TemporaryFolder();

    /**
     * Two requests can compile the same template concurrently, in which case only one of them wins
     * {@code putIfAbsent}. If the cache is cleared in between, the loser must still render its own template rather
     * than fail on a cache read that now returns nothing.
     */
    @Test
    public void processTemplateSurvivesCacheClearedWhileLosingPutIfAbsent() throws Exception {
        File themeDir = temporaryFolder.newFolder("login");
        Path template = themeDir.toPath().resolve("test.ftl");
        Files.writeString(template, "version-1", StandardCharsets.UTF_8);
        Theme theme = new FolderTheme(themeDir, "custom", LOGIN);

        ConcurrentHashMap<String, Template> cache = new ConcurrentHashMap<>() {
            @Override
            public Template putIfAbsent(String key, Template value) {
                // another request won the race, and the theme cache was cleared before this one read the entry back
                Template previous = super.putIfAbsent(key, value);
                clear();
                return previous == null ? value : previous;
            }
        };

        DefaultFreeMarkerProvider provider = new DefaultFreeMarkerProvider(cache, null);

        assertEquals("version-1", provider.processTemplate(new HashMap<>(), "test.ftl", theme));
    }
}
