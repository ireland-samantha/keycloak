package adv.lies;

import java.util.ArrayList;
import java.util.List;

/** Attack 1b: heap pollution through a raw type. */
public class Roles {

    private List<String> names = new ArrayList<>();

    /** The raw type is in this signature. */
    @SuppressWarnings({"rawtypes", "unchecked"})
    public void setLegacy(List legacy) {
        this.names = legacy;
    }

    /** No raw type in this signature: the pollution happens in the body. */
    @SuppressWarnings({"rawtypes", "unchecked"})
    public void merge(List<String> more) {
        List raw = names;
        raw.add(more.size());
    }

    public List<String> getNames() {
        return names;
    }
}
