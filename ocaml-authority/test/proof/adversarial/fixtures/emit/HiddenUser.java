package adv.emit;

import java.util.Set;

/** Attack 3e: a Set over a type whose name starts with an underscore needs a Set.Make module. */
public interface HiddenUser {

    Set<_Hidden> getHidden();
}
