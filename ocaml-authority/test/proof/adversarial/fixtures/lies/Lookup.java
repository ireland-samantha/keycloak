package adv.lies;

import java.util.Optional;

/** Attack 1e: Optional returned as null. */
public interface Lookup {

    Optional<String> find(String key);

    default Optional<String> literalNull() {
        return null;
    }

    default Optional<String> indirectNull() {
        Optional<String> none = null;
        return none;
    }
}
