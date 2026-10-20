package adv.lies;

import java.util.List;
import java.util.Map;

/** Attack 1a: the claims map is built by an unchecked cast, as AuthorizationTokenService.java:127 does. */
public class PushedClaims {

    private final Map<String, List<String>> claims;

    @SuppressWarnings("unchecked")
    public PushedClaims(String claimToken) {
        this.claims = (Map<String, List<String>>) MiniJson.readValue(claimToken, Map.class);
    }

    public Map<String, List<String>> getClaims() {
        return claims;
    }
}
