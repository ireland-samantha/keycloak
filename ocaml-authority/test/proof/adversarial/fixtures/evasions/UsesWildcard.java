package adv.consumer;

import adv.evasions.*;
import java.util.Set;

/** Attack 2e: a wildcard import of the slice package. Mode is the slice enum adv.evasions.Mode. */
public interface UsesWildcard {

    Set<Mode> getModes();

    Scope getScope();
}
