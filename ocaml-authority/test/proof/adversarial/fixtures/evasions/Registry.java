package adv.evasions;

import java.util.Set;

/** Attack 2a: type parameters named like slice types. */
public class Registry<Mode> {

    /** The class's own type parameter. */
    public Set<Mode> own() {
        return null;
    }

    /** An inner (non-static) class: Registry's Mode is still in scope and still the type parameter. */
    public class View {

        public Set<Mode> modes() {
            return null;
        }
    }

    /** A method type parameter named like a slice type. */
    public <Scope> Scope pick(Set<Scope> from) {
        return null;
    }
}
