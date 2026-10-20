package adv.lies;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/** Attack 1f: a setter that always throws, and a map that refuses writes. */
public class FrozenPolicy {

    private final Map<String, String> config = new HashMap<>();

    public String getName() {
        return "frozen";
    }

    public void setName(String name) {
        throw new UnsupportedOperationException("read-only policy");
    }

    public Map<String, String> getConfig() {
        return Collections.unmodifiableMap(config);
    }
}
