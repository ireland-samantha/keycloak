package adv.lies;

/** Attack 1c: a String that holds JSON, as KeycloakIdentity.java:128 stores the RFC 8693 act claim. */
public class DelegatedIdentity {

    /** {"sub":"...","act":{"sub":"..."}}, serialised into one string. */
    public final String actClaim;

    public DelegatedIdentity(String actClaim) {
        this.actClaim = actClaim;
    }

    public String getAct() {
        return actClaim;
    }
}
