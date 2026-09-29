package org.keycloak.theme.freemarker;

import org.keycloak.provider.ProviderFactory;

public interface FreeMarkerProviderFactory extends ProviderFactory<FreeMarkerProvider> {

    /**
     * Clears any compiled templates cached by this factory. Invoked when the theme cache is cleared so that changes
     * to theme templates are picked up.
     */
    default void clearCache() {
    }

}
