package adv.lies;

import java.util.Set;
import java.util.TreeSet;

/** Attack 1g (extra): a Set<String> whose uniqueness is not String.equals. */
public class ScopeNames {

    public Set<String> getNames() {
        Set<String> names = new TreeSet<>(String.CASE_INSENSITIVE_ORDER);
        names.add("Read");
        names.add("read");
        return names;
    }
}
